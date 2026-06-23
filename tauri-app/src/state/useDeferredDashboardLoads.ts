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
}: DeferredDashboardLoadsOptions) {
  usePreciseDashboardLoad({
    active,
    dashboardReady,
    generation,
    loading,
    onPreciseDashboard,
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
    source,
  });

  useLiveThreadOptionsLoad({
    active,
    dashboardReady,
    generation,
    loading,
    onLiveThreadOptions,
    source,
  });
}
