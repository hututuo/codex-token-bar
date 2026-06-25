import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { DashboardSnapshot } from "../types/dashboard";

interface PreciseDashboardLoadOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  source: Pick<DashboardDataSource, "readPreciseDashboardSnapshot">;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
  onLoadEnd?: () => void;
  onLoadStart?: () => void;
}

export function usePreciseDashboardLoad({
  active,
  dashboardReady,
  loading,
  generation,
  source,
  onPreciseDashboard,
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
        const precise = await source.readPreciseDashboardSnapshot();
        if (!cancelled && precise !== null) {
          onPreciseDashboard(precise);
        }
      } finally {
        onLoadEnd?.();
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
    };
  }, [active, dashboardReady, generation, loading, onLoadEnd, onLoadStart, onPreciseDashboard, source]);
}
