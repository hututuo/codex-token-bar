import { useCallback, useEffect, useRef, useState } from "react";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { readUsageSummarySnapshot } from "../api/dashboardClient";
import { readLiveRateSnapshot } from "../api/liveClient";
import { desktopPlatform } from "../platform/desktop";
import {
  createLiveRateLeaseController,
  type LiveRateLeaseController,
  tryCreateLiveRateOwnerSession,
} from "../state/liveRateLease";
import type {
  FloatingPanelSnapshot,
  LiveRateSnapshot,
  UnreadSummary,
  UsageSummarySnapshot,
} from "../types/dashboard";
import {
  LIVE_USAGE_ACTIVITY_HOLD_MS,
  liveRateHasUsageRefreshActivity,
  usageRefreshIntervalMs,
} from "../utils/usageRefreshCadence";
import {
  disabledFloatingLiveSnapshot,
  floatingSnapshotForLiveRate,
  liveRateStreamStartFailureSnapshot,
  mergeFloatingUsageSummary,
  preserveFloatingUsageSummary,
  resetFloatingUsageSummary,
  shouldResetCompactUsageSummarySource,
} from "./compactPanelSnapshotModel";
import { createCompactLiveRateAttemptRunner } from "./compactLiveRateAttempt";

interface CompactPanelSnapshotOptions {
  active: boolean;
  liveRateEnabled: boolean;
  liveRateOwnerToken: string;
  sourceKey?: string | null;
}

const COMPACT_USAGE_SUMMARY_REFRESH_INTERVAL_MS = 60_000;

export function useCompactPanelSnapshot({
  active,
  liveRateEnabled,
  liveRateOwnerToken,
  sourceKey = null,
}: CompactPanelSnapshotOptions): FloatingPanelSnapshot {
  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const [lastLiveActivityAtMs, setLastLiveActivityAtMs] = useState(0);
  const lastLiveActivityAtMsRef = useRef(0);
  const usageSummaryRef = useRef<UsageSummarySnapshot | null>(null);
  const usageSummarySourceKeyRef = useRef<string | null>(sourceKey);
  const leaseControllerRef = useRef<LiveRateLeaseController | null | undefined>(undefined);
  const liveRateAttemptRunnerRef = useRef(createCompactLiveRateAttemptRunner());
  let leaseController = leaseControllerRef.current;
  if (leaseController === undefined) {
    const ownerSession = tryCreateLiveRateOwnerSession(liveRateOwnerToken);
    leaseController = ownerSession === null
      ? null
      : createLiveRateLeaseController((leaseId) => {
          void desktopPlatform.stopLiveRateStream(leaseId);
        }, ownerSession);
    leaseControllerRef.current = leaseController;
  }

  const markLiveUsageActivity = useCallback((liveRate: LiveRateSnapshot) => {
    if (!liveRateHasUsageRefreshActivity(liveRate)) {
      return;
    }

    const nowMs = Date.now();
    lastLiveActivityAtMsRef.current = nowMs;
    setLastLiveActivityAtMs((current) => {
      if (current > 0 && nowMs - current < LIVE_USAGE_ACTIVITY_HOLD_MS) {
        return current;
      }
      return nowMs;
    });
  }, []);

  useEffect(() => {
    if (shouldResetCompactUsageSummarySource(
      usageSummarySourceKeyRef.current,
      sourceKey,
      usageSummaryRef.current !== null,
    )) {
      usageSummaryRef.current = null;
      setRawSnapshot(resetFloatingUsageSummary);
    }
    usageSummarySourceKeyRef.current = sourceKey;
  }, [sourceKey]);

  useEffect(() => {
    if (!active) {
      usageSummaryRef.current = null;
      usageSummarySourceKeyRef.current = sourceKey;
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      setRawSnapshot(emptyFloatingPanelSnapshot);
      return;
    }

    let cancelled = false;
    const refreshUsageSummary = async () => {
      const summary = await readUsageSummarySnapshot();
      if (cancelled) {
        return;
      }

      if (summary) {
        usageSummaryRef.current = summary;
        usageSummarySourceKeyRef.current = sourceKey;
        setRawSnapshot((current) => mergeFloatingUsageSummary(current, summary));
        return;
      }

      setRawSnapshot(preserveFloatingUsageSummary);
    };

    void refreshUsageSummary();
    const intervalMs = usageRefreshIntervalMs({
      baselineIntervalMs: COMPACT_USAGE_SUMMARY_REFRESH_INTERVAL_MS,
      lastLiveActivityAtMs,
    });
    const timer = setInterval(refreshUsageSummary, intervalMs);

    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [active, lastLiveActivityAtMs, sourceKey]);

  useEffect(() => {
    if (lastLiveActivityAtMs <= 0) {
      return;
    }

    const timer = setTimeout(() => {
      const latestActivityAtMs = lastLiveActivityAtMsRef.current;
      if (
        latestActivityAtMs > 0
        && Date.now() - latestActivityAtMs < LIVE_USAGE_ACTIVITY_HOLD_MS
      ) {
        setLastLiveActivityAtMs(latestActivityAtMs);
        return;
      }

      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
    }, LIVE_USAGE_ACTIVITY_HOLD_MS);

    return () => {
      clearTimeout(timer);
    };
  }, [lastLiveActivityAtMs]);

  useEffect(() => {
    if (!active || !liveRateEnabled) {
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      setRawSnapshot(disabledFloatingLiveSnapshot);
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;

    if (leaseController === null) {
      setRawSnapshot(floatingSnapshotForLiveRate(
        liveRateStreamStartFailureSnapshot("Live-rate owner epoch storage is unavailable"),
        usageSummaryRef.current,
      ));
      return;
    }
    let leaseRequest: ReturnType<LiveRateLeaseController["begin"]> | null = null;

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        markLiveUsageActivity(liveRate);
        setRawSnapshot(floatingSnapshotForLiveRate(liveRate, usageSummaryRef.current));
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    const attempt = liveRateAttemptRunnerRef.current.start({
      async start() {
        leaseRequest = leaseController.begin();
        const claimed = await desktopPlatform.claimLiveRateOwnerSession(
          leaseRequest.ownerToken,
          leaseRequest.ownerSessionEpoch,
        );
        if (!claimed) {
          return { ok: false, accepted: false, error: "实时速率流暂不可用" };
        }
        const result = await desktopPlatform.startLiveRateStreamCommand({
          selectedThreadId: null,
          controlsSelectedThread: false,
          subscriberOwnerToken: leaseRequest.ownerToken,
          ownerSessionEpoch: leaseRequest.ownerSessionEpoch,
          ownerGeneration: leaseRequest.ownerGeneration,
          sourceToken: null,
        });
        if (!result.ok || result.value === null) {
          return {
            ok: false,
            accepted: false,
            error: result.ok ? "实时速率流暂不可用" : result.error,
          };
        }
        return { ok: true, accepted: leaseRequest.accept(result.value) };
      },
      cancelStart() {
        leaseRequest?.cancel();
        leaseRequest = null;
      },
      readInitial: () => readLiveRateSnapshot(null),
      publishSnapshot(liveRate) {
        markLiveUsageActivity(liveRate);
        setRawSnapshot(floatingSnapshotForLiveRate(liveRate, usageSummaryRef.current));
      },
      publishFailure(message) {
        setRawSnapshot(floatingSnapshotForLiveRate(
          liveRateStreamStartFailureSnapshot(message),
          usageSummaryRef.current,
        ));
      },
    });

    return () => {
      cancelled = true;
      unlisten?.();
      attempt.cancel();
    };
  }, [active, liveRateEnabled, liveRateOwnerToken, markLiveUsageActivity, sourceKey]);

  useEffect(() => {
    if (!active || !liveRateEnabled) {
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    const applyUnreadSummary = (summary: UnreadSummary) => {
      setRawSnapshot((current) => ({
        ...current,
        unread: summary.active,
        unreadSummary: summary,
      }));
    };

    void desktopPlatform.onUnreadSummaryChanged((summary) => {
      if (!cancelled) {
        applyUnreadSummary(summary);
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [active, liveRateEnabled]);

  return rawSnapshot;
}
