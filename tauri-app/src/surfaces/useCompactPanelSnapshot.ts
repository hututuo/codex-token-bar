import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { readUsageSummarySnapshot } from "../api/dashboardClient";
import {
  readInitialLiveRateSnapshot,
  readUnreadSummary,
} from "../api/liveClient";
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
  DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS,
  sanitizeUsageLightRefreshIntervalSeconds,
} from "../settings/usageRefreshCadence";
import { readAppSettings } from "../api/client";
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
  readInitialLiveRate: typeof readInitialLiveRateSnapshot;
  readInitialUnread?: typeof readUnreadSummary;
  readUsageSummary: (
    sourceToken: CodexHomeSourceToken,
    refreshIntervalSeconds?: number,
  ) => Promise<UsageSummarySnapshot | null>;
}

const DEFAULT_SNAPSHOT_DEPENDENCIES: CompactPanelSnapshotDependencies = {
  platform: desktopPlatform,
  readInitialLiveRate: readInitialLiveRateSnapshot,
  readInitialUnread: readUnreadSummary,
  readUsageSummary: (sourceToken, refreshIntervalSeconds) => readUsageSummarySnapshot(
    sourceToken,
    refreshIntervalSeconds,
  ),
};

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
  const [usageSummaryRefreshIntervalSeconds, setUsageSummaryRefreshIntervalSeconds] = useState(
    DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS,
  );
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

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;
    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        setUsageSummaryRefreshIntervalSeconds(
          sanitizeUsageLightRefreshIntervalSeconds(settings.usageLightRefreshIntervalSeconds),
        );
      }
    }).catch(() => {});
    void desktopPlatform.onAppSettingsChanged((settings) => {
      setUsageSummaryRefreshIntervalSeconds(
        sanitizeUsageLightRefreshIntervalSeconds(settings.usageLightRefreshIntervalSeconds),
      );
    }).then((listener) => {
      if (cancelled) listener();
      else unlisten = listener;
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  useLayoutEffect(() => {
    if (sourceKeyRef.current !== sourceKey) {
      sourceKeyRef.current = sourceKey;
      usageSummaryRef.current = null;
      lastSmoothedLiveRateRef.current = null;
      lastLiveRateDisplayBucketRef.current = "";
      setRawSnapshot(emptyFloatingPanelSnapshot);
    }
  }, [sourceKey]);

  useEffect(() => {
    if (!active || sourceToken === null || sourceKey === null) {
      return;
    }

    let cancelled = false;
    const requestSourceKey = sourceKey;
    const requestSourceToken = sourceToken;
    const refreshUsageSummary = async () => {
      let summary: UsageSummarySnapshot | null = null;
      try {
        summary = await dependencies.readUsageSummary(
          requestSourceToken,
          usageSummaryRefreshIntervalSeconds,
        );
      } catch {
        // The command client records the native failure for diagnostics.
      }
      if (cancelled || sourceKeyRef.current !== requestSourceKey) {
        return;
      }
      if (summary) {
        usageSummaryRef.current = summary;
        setRawSnapshot((current) => mergeFloatingUsageSummary(current, summary));
        return;
      }

      // Both expected initialization and a background refresh failure retain
      // the last trusted numeric summary. The command layer distinguishes the
      // two for diagnostics; the compact surface must never regress to dashes.
      setRawSnapshot(preserveFloatingUsageSummary);
    };

    void refreshUsageSummary();
    const intervalMs = usageSummaryRefreshIntervalSeconds * 1_000;
    const timer = setInterval(refreshUsageSummary, intervalMs);

    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [active, dependencies, sourceKey, sourceToken, usageSummaryRefreshIntervalSeconds]);

  useEffect(() => {
    if (!active || sourceToken === null || sourceKey === null) {
      setRawSnapshot((current) => compactSnapshotForSurfaceActivity(
        current,
        active,
        liveRateEnabled,
      ));
      return;
    }
    if (!liveRateEnabled) {
      lastSmoothedLiveRateRef.current = null;
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
    sourceKey,
    sourceToken,
  ]);

  useEffect(() => {
    if (!active || sourceToken === null || sourceKey === null) {
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    const requestSourceKey = sourceKey;
    const applyUnreadSummary = (summary: UnreadSummary) => {
      if (cancelled || sourceKeyRef.current !== requestSourceKey) {
        return;
      }
      setRawSnapshot((current) => ({
        ...current,
        unread: summary.active,
        unreadSummary: summary,
      }));
    };

    void dependencies.readInitialUnread?.(sourceToken)
      .then(applyUnreadSummary)
      .catch(() => {
        // 保持 pending；缺失状态由状态栏统一显示为破折号。
      });

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
  }, [active, dependencies, sourceKey, sourceToken]);

  return rawSnapshot;
}
