import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { CodexHomeSourceToken, DashboardSnapshot, UsageCacheStatus } from "../types/dashboard";
import { loadPreciseDashboardSingleFlight } from "./preciseDashboardSingleFlight";

const PRECISE_DASHBOARD_UI_WAIT_MS = 30_000;

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
    let unsubscribePrecise: (() => void) | undefined;
    preciseGeneration.current = generation;

    async function loadPreciseSnapshot() {
      onLoadStart?.();
      try {
        const cacheStatus = await source.readUsageCacheStatus();
        if (!cancelled) {
          onUsageCacheStatus?.(cacheStatus);
        }
        if (cancelled || sourceToken === null) {
          return;
        }
        const preciseFlight = loadPreciseDashboardSingleFlight(
          sourceToken,
          () => source.readPreciseDashboardSnapshot(sourceToken),
          (precise) => {
            if (!cancelled && precise !== null) {
              onPreciseDashboard(precise);
              onUsageCacheInitialized?.();
            }
          },
        );
        unsubscribePrecise = preciseFlight.unsubscribe;
        // The native owner keeps running after this soft UI budget. Ending the
        // visible refresh state does not release the single-flight entry or
        // enqueue another Rust scan; a late current result still publishes.
        await preciseFlight.waitForUiBudget(PRECISE_DASHBOARD_UI_WAIT_MS);
      } finally {
        onLoadEnd?.();
      }
    }

    void loadPreciseSnapshot();

    return () => {
      cancelled = true;
      unsubscribePrecise?.();
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
