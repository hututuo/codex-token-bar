import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { CodexHomeSourceToken, DashboardSnapshot, UsageCacheStatus } from "../types/dashboard";

interface PreciseDashboardLoadOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<DashboardDataSource, "readPreciseDashboardSnapshot" | "readUsageCacheStatus">;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
  onUsageCacheInitialized?: () => void;
  onUsageCacheStatus?: (status: UsageCacheStatus) => void;
  onLoadEnd?: () => void;
  onLoadStart?: () => void;
}

export function usePreciseDashboardLoad({
  active,
  dashboardReady,
  loading,
  generation,
  sourceToken,
  source,
  onPreciseDashboard,
  onUsageCacheInitialized,
  onUsageCacheStatus,
  onLoadEnd,
  onLoadStart,
}: PreciseDashboardLoadOptions) {
  const preciseGeneration = useRef<number | null>(null);

  useEffect(() => {
    if (!active || !dashboardReady || loading || preciseGeneration.current === generation) {
      return;
    }

    let cancelled = false;
    preciseGeneration.current = generation;

    async function loadPreciseSnapshot() {
      onLoadStart?.();
      try {
        const cacheStatus = await source.readUsageCacheStatus();
        if (!cancelled) {
          onUsageCacheStatus?.(cacheStatus);
        }
        if (sourceToken === null) {
          return;
        }
        const precise = await source.readPreciseDashboardSnapshot(sourceToken);
        if (!cancelled && precise !== null) {
          onPreciseDashboard(precise);
          onUsageCacheInitialized?.();
        }
      } finally {
        onLoadEnd?.();
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
    };
  }, [
    active,
    dashboardReady,
    generation,
    loading,
    onLoadEnd,
    onLoadStart,
    onPreciseDashboard,
    onUsageCacheInitialized,
    onUsageCacheStatus,
    source,
    sourceToken,
  ]);
}
