import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { CodexHomeSourceToken, DashboardSnapshot, UsageCacheStatus } from "../types/dashboard";
import {
  loadPreciseDashboardSingleFlight,
  markPreciseDashboardSourceDirty,
} from "./preciseDashboardSingleFlight";
import {
  initialPreciseDashboardDeadlineMs,
  preciseDashboardStartDelayMs,
} from "./preciseDashboardSchedule";

const PRECISE_DASHBOARD_UI_WAIT_MS = 30_000;

interface PreciseDashboardLoadOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  forcePreciseRefresh?: boolean;
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<DashboardDataSource, "readPreciseDashboardSnapshot" | "readUsageCacheStatus">;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
  onPreciseDashboardFailure?: () => void;
  onPreciseDashboardStale?: () => void;
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
  forcePreciseRefresh = true,
  sourceToken,
  source,
  onPreciseDashboard,
  onPreciseDashboardFailure,
  onPreciseDashboardStale,
  onUsageCacheInitialized,
  onUsageCacheStatus,
  onLoadEnd,
  onLoadStart,
}: PreciseDashboardLoadOptions) {
  const preciseGeneration = useRef<number | null>(null);
  const initialStartDeadlineMs = useRef<number | null>(null);

  useEffect(() => {
    if (!active || !dashboardReady || loading || preciseGeneration.current === generation) {
      return;
    }

    let cancelled = false;
    let unsubscribePrecise: (() => void) | undefined;
    if (forcePreciseRefresh && sourceToken !== null) {
      // Keep a failed explicit request retryable even when the optional
      // cache-status command rejects before the native precise loader starts.
      markPreciseDashboardSourceDirty(sourceToken);
    }
    const nowMs = window.performance.now();
    initialStartDeadlineMs.current = initialPreciseDashboardDeadlineMs(
      initialStartDeadlineMs.current,
      nowMs,
    );
    const startDelayMs = preciseDashboardStartDelayMs(
      preciseGeneration.current,
      initialStartDeadlineMs.current,
      nowMs,
    );

    async function loadPreciseSnapshot() {
      // A new exact read owns freshness until it publishes a full snapshot.
      // If cache-status, native indexing, or the optional command fails, this
      // explicit false remains instead of trusting the previous canvas.
      onPreciseDashboardStale?.();
      onLoadStart?.();
      let failureReported = false;
      const reportFailure = () => {
        if (!cancelled && !failureReported) {
          failureReported = true;
          onPreciseDashboardFailure?.();
        }
      };
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
          { force: forcePreciseRefresh },
        );
        unsubscribePrecise = preciseFlight.unsubscribe;
        void preciseFlight.result.then(
          (result) => {
            if (result === null
              || result.preciseRecentUsageFresh !== true
              || !result.preciseRecentUsageCoveredAt) {
              reportFailure();
            }
          },
          reportFailure,
        );
        // The native owner keeps running after this soft UI budget. Ending the
        // visible refresh state does not release the single-flight entry or
        // enqueue another Rust scan; a late current result still publishes.
        await preciseFlight.waitForUiBudget(PRECISE_DASHBOARD_UI_WAIT_MS);
      } catch {
        reportFailure();
      } finally {
        onLoadEnd?.();
      }
    }

    const startTimer = window.setTimeout(() => {
      if (!cancelled) {
        // Do not claim the generation until the delayed work actually starts. An
        // unrelated render can tear down this effect during the startup grace
        // period; marking it earlier would make the replacement effect believe
        // the exact scan had already run and permanently skip that generation.
        preciseGeneration.current = generation;
        void loadPreciseSnapshot();
      }
    }, startDelayMs);

    return () => {
      cancelled = true;
      window.clearTimeout(startTimer);
      unsubscribePrecise?.();
    };
  }, [
    active,
    dashboardReady,
    forcePreciseRefresh,
    generation,
    loading,
    onLoadEnd,
    onLoadStart,
    onPreciseDashboard,
    onPreciseDashboardFailure,
    onPreciseDashboardStale,
    onUsageCacheInitialized,
    onUsageCacheStatus,
    source,
    sourceToken,
  ]);
}
