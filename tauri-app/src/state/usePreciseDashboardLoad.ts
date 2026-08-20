import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { CodexHomeSourceToken, DashboardSnapshot, UsageCacheStatus } from "../types/dashboard";
import type {
  PreciseDashboardDedupeDomain,
  PreciseDashboardRefreshReason,
  PreciseDashboardRequestRevision,
} from "../types/usage";
import {
  loadPreciseDashboardSingleFlight,
  markPreciseDashboardSourceDirty,
  preciseDashboardForceRequestCanReuseSettled,
  preciseDashboardFlightInProgress,
} from "./preciseDashboardSingleFlight";
import {
  initialPreciseDashboardDeadlineMs,
  preciseDashboardStartDelayMs,
} from "./preciseDashboardSchedule";
import {
  classifyPreciseIndexUpgradeRequired,
  PreciseIndexUpgradeRequiredError,
  type PreciseIndexUpgradeRequired,
} from "../api/preciseIndexCompatibility";

const PRECISE_DASHBOARD_UI_WAIT_MS = 30_000;

interface PreciseDashboardLoadOptions {
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
  sourceToken: CodexHomeSourceToken | null;
  source: Pick<
    DashboardDataSource,
    "readPreciseDashboardSnapshot" | "readPreciseDashboardSourceProbe" | "readUsageCacheStatus"
  >;
  onPreciseDashboard: (snapshot: DashboardSnapshot) => void;
  onPreciseDashboardFailure?: () => void;
  onPreciseIndexUpgradeRequired?: (upgrade: PreciseIndexUpgradeRequired) => void;
  onPreciseDashboardStale?: () => void;
  onUsageCacheInitialized?: () => void;
  onUsageCacheStatus?: (status: UsageCacheStatus) => void;
  onPreciseRequestStarted?: (
    generation: number,
    forced: boolean,
    reason: PreciseDashboardRefreshReason,
    revision?: PreciseDashboardRequestRevision,
    dedupeDomain?: PreciseDashboardDedupeDomain,
    dedupeKey?: string,
  ) => void;
  onPreciseRequestSettled?: () => void;
  onLoadEnd?: () => void;
  onLoadStart?: () => void;
}

export function usePreciseDashboardLoad({
  active,
  dashboardReady,
  startupUnavailable = false,
  loading,
  generation,
  forcePreciseRefresh = true,
  preciseRefreshReason,
  preciseRefreshRevision,
  preciseRefreshDedupeDomain,
  preciseRefreshDedupeKey,
  sourceToken,
  source,
  onPreciseDashboard,
  onPreciseDashboardFailure,
  onPreciseIndexUpgradeRequired,
  onPreciseDashboardStale,
  onUsageCacheInitialized,
  onUsageCacheStatus,
  onPreciseRequestStarted,
  onPreciseRequestSettled,
  onLoadEnd,
  onLoadStart,
}: PreciseDashboardLoadOptions) {
  const preciseGeneration = useRef<number | null>(null);
  const initialStartDeadlineMs = useRef<number | null>(null);

  useEffect(() => {
    if (
      !active
      || (!dashboardReady && !startupUnavailable)
      || (loading && !startupUnavailable)
      || preciseGeneration.current === generation
    ) {
      return;
    }

    let cancelled = false;
    let unsubscribePrecise: (() => void) | undefined;
    const requestReason = preciseRefreshReason ?? (forcePreciseRefresh ? "unknown" : "cadence");
    const canDeferDirtyMark = forcePreciseRefresh
      && preciseDashboardForceRequestCanReuseSettled(
        requestReason,
        preciseRefreshRevision,
        preciseRefreshDedupeDomain,
        preciseRefreshDedupeKey,
      );
    if (forcePreciseRefresh && sourceToken !== null && !canDeferDirtyMark) {
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
      // Keep the last trusted canvas current while a replacement is in flight.
      // A background refresh is not evidence that the published data became
      // invalid; only an actual failed/incomplete result may mark it stale.
      onLoadStart?.();
      let effectiveForce = forcePreciseRefresh;
      let publishedGeneration: string | undefined;
      let failureReported = false;
      let upgradeReported = false;
      let settlementBoundToNativeFlight = false;
      const reportFailure = () => {
        if (!cancelled && !failureReported) {
          failureReported = true;
          onPreciseDashboardStale?.();
          onPreciseDashboardFailure?.();
        }
      };
      const reportError = (error: unknown) => {
        const upgrade = error instanceof PreciseIndexUpgradeRequiredError
          ? error.details
          : classifyPreciseIndexUpgradeRequired(error);
        if (upgrade !== null) {
          if (!cancelled && !upgradeReported) {
            upgradeReported = true;
            onPreciseIndexUpgradeRequired?.(upgrade);
          }
          return true;
        }
        reportFailure();
        return false;
      };
      try {
        const cacheStatus = await source.readUsageCacheStatus();
        if (!cancelled) {
          onUsageCacheStatus?.(cacheStatus);
        }
        if (cancelled || sourceToken === null) {
          return;
        }
        if (!forcePreciseRefresh
          && !preciseDashboardFlightInProgress(sourceToken)) {
          // Cadence requests must prove that the source is unchanged before
          // reusing a last-good exact snapshot. A missing, changed, or failed
          // probe is deliberately fail-safe: keep the source dirty and enter
          // the native precise owner.
          let sourceProbe = null;
          try {
            sourceProbe = await source.readPreciseDashboardSourceProbe(sourceToken);
          } catch {
            sourceProbe = null;
          }
          if (cancelled) {
            return;
          }
          // A forced owner may have started while the probe was in flight. It
          // now covers this cadence tick; join it without manufacturing a
          // trailing run from the probe's transient `building_generation`.
          if (preciseDashboardFlightInProgress(sourceToken)) {
            effectiveForce = false;
            publishedGeneration = undefined;
          } else if (sourceProbe?.state !== "unchanged") {
            effectiveForce = true;
            markPreciseDashboardSourceDirty(sourceToken);
          } else if (
            typeof sourceProbe?.publishedGeneration === "string"
            && /^(0|[1-9]\d*)$/.test(sourceProbe.publishedGeneration)
          ) {
            publishedGeneration = sourceProbe.publishedGeneration;
          } else {
            // An unchanged source without a canonical published generation
            // cannot prove that the in-memory dashboard belongs to the same
            // exact index lineage. Fail safe to the native owner.
            effectiveForce = true;
            markPreciseDashboardSourceDirty(sourceToken);
          }
        }
        const preciseFlight = loadPreciseDashboardSingleFlight(
          sourceToken,
          () => source.readPreciseDashboardSnapshot(sourceToken, requestReason),
          (precise) => {
            if (!cancelled && precise !== null) {
              onPreciseDashboard(precise);
              onUsageCacheInitialized?.();
            }
          },
          {
            force: effectiveForce,
            publishedGeneration,
            reason: requestReason,
            revision: preciseRefreshRevision,
            dedupeDomain: preciseRefreshDedupeDomain,
            dedupeKey: preciseRefreshDedupeKey,
          },
        );
        unsubscribePrecise = preciseFlight.unsubscribe;
        settlementBoundToNativeFlight = true;
        void preciseFlight.result.then(
          () => onPreciseRequestSettled?.(),
          () => onPreciseRequestSettled?.(),
        );
        void preciseFlight.result.then(
          (result) => {
            if (result === null
              || result.preciseRecentUsageFresh !== true
              || !(result.preciseRecentUsageCoveredAt ?? result.settledThrough)) {
              reportFailure();
            }
          },
          reportError,
        );
        // The native owner keeps running after this soft UI budget. Ending the
        // visible refresh state does not release the single-flight entry or
        // enqueue another Rust scan; a late current result still publishes.
        await preciseFlight.waitForUiBudget(PRECISE_DASHBOARD_UI_WAIT_MS);
      } catch (error) {
        if (reportError(error)) {
          return;
        }
        if (forcePreciseRefresh && sourceToken !== null && canDeferDirtyMark) {
          // A coalescible force request that failed before single-flight was
          // reached still needs a dirty marker so the next retry cannot reuse
          // the previous settled snapshot.
          markPreciseDashboardSourceDirty(sourceToken);
        }
      } finally {
        if (!settlementBoundToNativeFlight) {
          onPreciseRequestSettled?.();
        }
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
        onPreciseRequestStarted?.(
          generation,
          forcePreciseRefresh,
          requestReason,
          preciseRefreshRevision,
          preciseRefreshDedupeDomain,
          preciseRefreshDedupeKey,
        );
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
    startupUnavailable,
    onLoadEnd,
    onLoadStart,
    onPreciseDashboard,
    onPreciseDashboardFailure,
    onPreciseIndexUpgradeRequired,
    onPreciseDashboardStale,
    onPreciseRequestSettled,
    onUsageCacheInitialized,
    onUsageCacheStatus,
    onPreciseRequestStarted,
    preciseRefreshReason,
    preciseRefreshRevision,
    preciseRefreshDedupeDomain,
    preciseRefreshDedupeKey,
    source,
    sourceToken,
  ]);
}
