import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { AccountQuotaBundle, DashboardSnapshot, LiveThreadOption } from "../types/dashboard";

interface DeferredDashboardLoadsOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
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
  forceQuotaRefresh,
  source,
  onPreciseDashboard,
  onQuota,
  onLiveThreadOptions,
  onForceQuotaRefreshConsumed,
}: DeferredDashboardLoadsOptions) {
  const preciseGeneration = useRef<number | null>(null);
  const quotaGeneration = useRef<number | null>(null);
  const liveThreadOptionsGeneration = useRef<number | null>(null);

  useEffect(() => {
    if (!active || !dashboardReady || loading || preciseGeneration.current === generation) {
      return;
    }

    let cancelled = false;
    preciseGeneration.current = generation;

    async function loadPreciseSnapshot() {
      const precise = await source.readPreciseDashboardSnapshot();
      if (!cancelled && precise !== null) {
        onPreciseDashboard(precise);
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
    };
  }, [active, dashboardReady, generation, loading, onPreciseDashboard, source]);

  useEffect(() => {
    if (!active || !dashboardReady || loading || quotaGeneration.current === generation) {
      return;
    }

    let cancelled = false;
    quotaGeneration.current = generation;
    const shouldForceRefresh = forceQuotaRefresh;
    const delayMs = shouldForceRefresh ? 0 : 5_000;

    async function loadQuota() {
      try {
        const quota = await source.readAccountQuota(shouldForceRefresh);
        if (!cancelled && quota !== null) {
          onQuota(quota);
        }
      } finally {
        if (shouldForceRefresh && !cancelled) {
          onForceQuotaRefreshConsumed();
        }
      }
    }

    const timer = window.setTimeout(() => {
      void loadQuota();
    }, delayMs);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [
    active,
    dashboardReady,
    forceQuotaRefresh,
    generation,
    loading,
    onForceQuotaRefreshConsumed,
    onQuota,
    source,
  ]);

  useEffect(() => {
    if (
      !active ||
      !dashboardReady ||
      loading ||
      liveThreadOptionsGeneration.current === generation
    ) {
      return;
    }

    let cancelled = false;
    liveThreadOptionsGeneration.current = generation;

    async function loadThreadOptions() {
      const liveThreadOptions = await source.readLiveThreadOptions();
      if (!cancelled) {
        onLiveThreadOptions(liveThreadOptions);
      }
    }

    void loadThreadOptions();

    return () => {
      cancelled = true;
    };
  }, [active, dashboardReady, generation, loading, onLiveThreadOptions, source]);
}
