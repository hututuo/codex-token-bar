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
}

export function usePreciseDashboardLoad({
  active,
  dashboardReady,
  loading,
  generation,
  source,
  onPreciseDashboard,
}: PreciseDashboardLoadOptions) {
  const preciseGeneration = useRef<number | null>(null);

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
}
