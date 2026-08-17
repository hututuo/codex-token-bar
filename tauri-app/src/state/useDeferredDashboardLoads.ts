import type { DashboardDataSource } from "../data/dashboardDataSource";
import type {
  AccountQuotaBundle,
  CodexHomeSourceToken,
  DashboardSnapshot,
  LiveThreadOption,
  PreciseDashboardDedupeDomain,
  PreciseDashboardRefreshReason,
  PreciseDashboardRequestRevision,
  UsageCacheStatus,
} from "../types/dashboard";
import type { ResetCreditBundle } from "../types/quota";
import { useDeferredQuotaLoad } from "./useDeferredQuotaLoad";
import { useLiveThreadOptionsLoad } from "./useLiveThreadOptionsLoad";
import { usePreciseDashboardLoad } from "./usePreciseDashboardLoad";

interface DeferredDashboardLoadsOptions {
  active: boolean;
  dashboardReady: boolean;
  startupUnavailable?: boolean;
  loading: boolean;
  generation: number;
  forcePreciseRefresh?: boolean;
  preciseRefreshReason?: PreciseDashboardRefreshReason;
  preciseRefreshRevision?: PreciseDashboardRequestRevision;
  preciseRefreshDedupeDomain?: PreciseDashboardDedupeDomain;
  preciseRefreshDedupeKey?: string;
  quotaGeneration: number;
  forceQuotaRefresh: boolean;
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<
    DashboardDataSource,
    | "readPreciseDashboardSnapshot"
    | "readPreciseDashboardSourceProbe"
    | "readUsageCacheStatus"
    | "readAccountQuota"
    | "readAccountResetCredits"
    | "readLiveThreadOptions"
  >;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
  onPreciseDashboardFailure?: () => void;
  onPreciseDashboardStale?: () => void;
  onUsageCacheInitialized: () => void;
  onUsageCacheStatus: (status: UsageCacheStatus) => void;
  onPreciseRequestStarted?: (
    generation: number,
    forced: boolean,
    reason: PreciseDashboardRefreshReason,
    revision?: PreciseDashboardRequestRevision,
    dedupeDomain?: PreciseDashboardDedupeDomain,
    dedupeKey?: string,
  ) => void;
  onQuota: (quota: AccountQuotaBundle) => void;
  onResetCredits: (reset: ResetCreditBundle) => void;
  onLiveThreadOptions: (options: LiveThreadOption[]) => void;
  onForceQuotaRefreshConsumed: () => void;
  onRefreshTaskEnd?: () => void;
  onRefreshTaskStart?: () => void;
}

export function useDeferredDashboardLoads({
  active,
  dashboardReady,
  startupUnavailable = false,
  loading,
  generation,
  forcePreciseRefresh,
  preciseRefreshReason,
  preciseRefreshRevision,
  preciseRefreshDedupeDomain,
  preciseRefreshDedupeKey,
  quotaGeneration,
  forceQuotaRefresh,
  sourceToken,
  source,
  onPreciseDashboard,
  onPreciseDashboardFailure,
  onPreciseDashboardStale,
  onUsageCacheInitialized,
  onUsageCacheStatus,
  onPreciseRequestStarted,
  onQuota,
  onResetCredits,
  onLiveThreadOptions,
  onForceQuotaRefreshConsumed,
  onRefreshTaskEnd,
  onRefreshTaskStart,
}: DeferredDashboardLoadsOptions) {
  usePreciseDashboardLoad({
    active,
    dashboardReady,
    startupUnavailable,
    generation,
    forcePreciseRefresh,
    preciseRefreshReason,
    preciseRefreshRevision,
    preciseRefreshDedupeDomain,
    preciseRefreshDedupeKey,
    loading,
    onPreciseDashboard,
    onPreciseDashboardFailure,
    onPreciseDashboardStale,
    onUsageCacheInitialized,
    onUsageCacheStatus,
    onPreciseRequestStarted,
    onLoadEnd: onRefreshTaskEnd,
    onLoadStart: onRefreshTaskStart,
    source,
    sourceToken,
  });

  useDeferredQuotaLoad({
    active,
    dashboardReady,
    forceQuotaRefresh,
    generation: quotaGeneration,
    onForceQuotaRefreshConsumed,
    onQuota,
    onResetCredits,
    onLoadEnd: onRefreshTaskEnd,
    onLoadStart: onRefreshTaskStart,
    source,
    sourceToken,
  });

  useLiveThreadOptionsLoad({
    active,
    dashboardReady,
    generation,
    loading,
    onLiveThreadOptions,
    onLoadEnd: onRefreshTaskEnd,
    onLoadStart: onRefreshTaskStart,
    source,
  });
}
