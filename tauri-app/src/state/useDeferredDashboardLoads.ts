import type { DashboardDataSource } from "../data/dashboardDataSource";
import type {
  AccountQuotaBundle,
  CodexHomeSourceToken,
  DashboardSnapshot,
  LiveThreadOption,
  UsageCacheStatus,
} from "../types/dashboard";
import { useDeferredQuotaLoad } from "./useDeferredQuotaLoad";
import { useLiveThreadOptionsLoad } from "./useLiveThreadOptionsLoad";
import { usePreciseDashboardLoad } from "./usePreciseDashboardLoad";

interface DeferredDashboardLoadsOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  quotaGeneration: number;
  forceQuotaRefresh: boolean;
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<
    DashboardDataSource,
    | "readPreciseDashboardSnapshot"
    | "readUsageCacheStatus"
    | "readAccountQuota"
    | "readLiveThreadOptions"
  >;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
  onUsageCacheInitialized: () => void;
  onUsageCacheStatus: (status: UsageCacheStatus) => void;
  onQuota: (quota: AccountQuotaBundle) => void;
  onLiveThreadOptions: (options: LiveThreadOption[]) => void;
  onForceQuotaRefreshConsumed: () => void;
  onRefreshTaskEnd?: () => void;
  onRefreshTaskStart?: () => void;
}

export function useDeferredDashboardLoads({
  active,
  dashboardReady,
  loading,
  generation,
  quotaGeneration,
  forceQuotaRefresh,
  sourceToken,
  source,
  onPreciseDashboard,
  onUsageCacheInitialized,
  onUsageCacheStatus,
  onQuota,
  onLiveThreadOptions,
  onForceQuotaRefreshConsumed,
  onRefreshTaskEnd,
  onRefreshTaskStart,
}: DeferredDashboardLoadsOptions) {
  usePreciseDashboardLoad({
    active,
    dashboardReady,
    generation,
    loading,
    onPreciseDashboard,
    onUsageCacheInitialized,
    onUsageCacheStatus,
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
    loading,
    onForceQuotaRefreshConsumed,
    onQuota,
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
