import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { readUsageSummarySnapshot } from "../api/dashboardClient";
import { readLiveRateSnapshotStrict } from "../api/liveClient";
import {
  changedLiveRateDisplayBucket,
  smoothLiveRateSnapshot,
} from "../components/liveRate/rateDisplay";
import { desktopPlatform } from "../platform/desktop";
import {
  createLiveRateLeaseController,
  type LiveRateLeaseController,
  tryCreateLiveRateOwnerSession,
} from "../state/liveRateLease";
import type {
  CodexHomeSourceToken,
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
  compactSnapshotForSurfaceActivity,
  floatingSnapshotForLiveRate,
  liveRateStreamStartFailureSnapshot,
  mergeFloatingUsageSummary,
  preserveFloatingUsageSummary,
} from "./compactPanelSnapshotModel";
import {
  createCompactLiveRateAttemptRunner,
  type CompactLiveRateAttemptHandle,
} from "./compactLiveRateAttempt";
import { codexHomeSourceTokenKey } from "./useCompactPanelSource";

interface CompactPanelSnapshotOptions {
  active: boolean;
  liveRateEnabled: boolean;
  liveRateOwnerToken: string;
  sourceToken: CodexHomeSourceToken | null;
}

interface CompactPanelSnapshotDependencies {
  platform: Pick<typeof desktopPlatform,
    | "claimLiveRateOwnerSession"
    | "onLiveRateSnapshot"
    | "onUnreadSummaryChanged"
    | "startLiveRateStreamCommand"
    | "stopLiveRateStream"
  >;
  readInitialLiveRate: typeof readLiveRateSnapshotStrict;
  readUsageSummary: (
    sourceToken: CodexHomeSourceToken,
  ) => Promise<UsageSummarySnapshot | null>;
}

const DEFAULT_SNAPSHOT_DEPENDENCIES: CompactPanelSnapshotDependencies = {
  platform: desktopPlatform,
  readInitialLiveRate: readLiveRateSnapshotStrict,
  readUsageSummary: (sourceToken) => readUsageSummarySnapshot(sourceToken),
};

const COMPACT_USAGE_SUMMARY_REFRESH_INTERVAL_MS = 60_000;

export function useCompactPanelSnapshot({
  active,
  liveRateEnabled,
  liveRateOwnerToken,
  sourceToken,
}: CompactPanelSnapshotOptions,
dependencies: CompactPanelSnapshotDependencies = DEFAULT_SNAPSHOT_DEPENDENCIES,
): FloatingPanelSnapshot {
  const sourceKey = codexHomeSourceTokenKey(sourceToken);
  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const [lastLiveActivityAtMs, setLastLiveActivityAtMs] = useState(0);
  const lastLiveActivityAtMsRef = useRef(0);
  const lastSmoothedLiveRateRef = useRef<LiveRateSnapshot | null>(null);
  const lastLiveRateDisplayBucketRef = useRef("");
  const usageSummaryRef = useRef<UsageSummarySnapshot | null>(null);
  const sourceKeyRef = useRef<string | null>(sourceKey);
  const leaseControllerRef = useRef<LiveRateLeaseController | null | undefined>(undefined);
  const liveRateAttemptRunnerRef = useRef(createCompactLiveRateAttemptRunner());
  let leaseController = leaseControllerRef.current;
  if (leaseController === undefined) {
    const ownerSession = tryCreateLiveRateOwnerSession(liveRateOwnerToken);
    leaseController = ownerSession === null
      ? null
      : createLiveRateLeaseController((leaseId) => {
          void dependencies.platform.stopLiveRateStream(leaseId);
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

  useLayoutEffect(() => {
    if (sourceKeyRef.current !== sourceKey) {
      sourceKeyRef.current = sourceKey;
      usageSummaryRef.current = null;
      lastSmoothedLiveRateRef.current = null;
      lastLiveRateDisplayBucketRef.current = "";
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      setRawSnapshot(emptyFloatingPanelSnapshot);
    }
  }, [sourceKey]);

  useEffect(() => {
    if (!active || sourceToken === null || sourceKey === null) {
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      return;
    }

    let cancelled = false;
    const requestSourceKey = sourceKey;
    const requestSourceToken = sourceToken;
    const refreshUsageSummary = async () => {
      const summary = await dependencies.readUsageSummary(requestSourceToken);
      if (cancelled || sourceKeyRef.current !== requestSourceKey) {
        return;
      }

      if (summary) {
        usageSummaryRef.current = summary;
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
  }, [active, dependencies, lastLiveActivityAtMs, sourceKey, sourceToken]);

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
    if (!active || sourceToken === null || sourceKey === null) {
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      setRawSnapshot((current) => compactSnapshotForSurfaceActivity(
        current,
        active,
        liveRateEnabled,
      ));
      return;
    }
    if (!liveRateEnabled) {
      lastSmoothedLiveRateRef.current = null;
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      setRawSnapshot((current) => compactSnapshotForSurfaceActivity(
        current,
        active,
        liveRateEnabled,
      ));
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    const requestSourceKey = sourceKey;
    const sourceIsCurrent = () => (
      !cancelled && sourceKeyRef.current === requestSourceKey
    );
    const publishLiveRate = (liveRate: LiveRateSnapshot) => {
      const smoothed = smoothLiveRateSnapshot(liveRate, lastSmoothedLiveRateRef.current);
      lastSmoothedLiveRateRef.current = smoothed;
      markLiveUsageActivity(smoothed);
      const bucket = changedLiveRateDisplayBucket(
        lastLiveRateDisplayBucketRef.current,
        smoothed,
      );
      if (bucket === null) {
        return;
      }
      lastLiveRateDisplayBucketRef.current = bucket;
      setRawSnapshot(floatingSnapshotForLiveRate(smoothed, usageSummaryRef.current));
    };

    if (leaseController === null) {
      publishLiveRate(liveRateStreamStartFailureSnapshot(
        "Live-rate owner epoch storage is unavailable",
      ));
      return;
    }
    let leaseRequest: ReturnType<LiveRateLeaseController["begin"]> | null = null;
    let attempt: CompactLiveRateAttemptHandle | null = null;

    void dependencies.platform.onLiveRateSnapshot((liveRate) => {
      if (sourceIsCurrent()) {
        attempt?.noteExternalSuccess();
        publishLiveRate(liveRate);
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    attempt = liveRateAttemptRunnerRef.current.start({
      async start() {
        leaseRequest = leaseController.begin();
        const claimed = await dependencies.platform.claimLiveRateOwnerSession(
          leaseRequest.ownerToken,
          leaseRequest.ownerSessionEpoch,
          sourceToken,
        );
        if (!claimed || !sourceIsCurrent()) {
          return { ok: false, accepted: false, error: "实时速率流暂不可用" };
        }
        const result = await dependencies.platform.startLiveRateStreamCommand({
          selectedThreadId: null,
          controlsSelectedThread: false,
          subscriberOwnerToken: leaseRequest.ownerToken,
          ownerSessionEpoch: leaseRequest.ownerSessionEpoch,
          ownerGeneration: leaseRequest.ownerGeneration,
          sourceToken,
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
      readInitial: () => dependencies.readInitialLiveRate(null, sourceToken),
      publishSnapshot(liveRate) {
        if (!sourceIsCurrent()) {
          return;
        }
        publishLiveRate(liveRate);
      },
      publishFailure(message) {
        if (!sourceIsCurrent()) {
          return;
        }
        publishLiveRate(liveRateStreamStartFailureSnapshot(message));
      },
    });

    return () => {
      cancelled = true;
      unlisten?.();
      attempt?.cancel();
    };
  }, [
    active,
    dependencies,
    liveRateEnabled,
    liveRateOwnerToken,
    markLiveUsageActivity,
    sourceKey,
    sourceToken,
  ]);

  useEffect(() => {
    if (!active || !liveRateEnabled || sourceKey === null) {
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    const requestSourceKey = sourceKey;
    const applyUnreadSummary = (summary: UnreadSummary) => {
      setRawSnapshot((current) => ({
        ...current,
        unread: summary.active,
        unreadSummary: summary,
      }));
    };

    void dependencies.platform.onUnreadSummaryChanged((payload) => {
      if (
        !cancelled
        && sourceKeyRef.current === requestSourceKey
        && codexHomeSourceTokenKey(payload.sourceToken) === requestSourceKey
      ) {
        applyUnreadSummary(payload.summary);
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
  }, [active, dependencies, liveRateEnabled, sourceKey]);

  return rawSnapshot;
}
