import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { AccountQuotaBundle, DashboardSnapshot, LiveThreadOption } from "../types/dashboard";
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
  source: Pick<
    DashboardDataSource,
    "readPreciseDashboardSnapshot" | "readAccountQuota" | "readLiveThreadOptions"
  >;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
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
  source,
  onPreciseDashboard,
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
    onLoadEnd: onRefreshTaskEnd,
    onLoadStart: onRefreshTaskStart,
    source,
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
