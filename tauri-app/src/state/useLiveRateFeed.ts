import { useEffect, useRef } from "react";
import { readLiveRateSnapshotStrict } from "../api/liveClient";
import {
  changedLiveRateDisplayBucket,
  smoothLiveRateSnapshot,
} from "../components/liveRate/rateDisplay";
import type { PlatformCommandResult } from "../platform/desktopBridge";
import { desktopPlatform } from "../platform/desktop";
import type { LiveRateSnapshot } from "../types/dashboard";
import type { DashboardSourceToken } from "./dashboardSourceTransition";
import {
  createLiveRateLeaseController,
  type LiveRateLeaseController,
  tryCreateLiveRateOwnerSession,
} from "./liveRateLease";
import { liveRateStreamFailureSnapshot } from "./liveRateStreamFailure";

interface LiveRateFeedOptions {
  active: boolean;
  selectedThreadId: string;
  sourceToken: DashboardSourceToken | null;
  onSnapshot: (snapshot: LiveRateSnapshot) => void;
  retryGeneration?: number;
}

interface LiveRateFeedDependencies {
  platform: Pick<typeof desktopPlatform,
    | "claimLiveRateOwnerSession"
    | "onLiveRateSnapshot"
    | "startLiveRateStreamCommand"
    | "stopLiveRateStream"
  >;
  readInitialLiveRate: typeof readLiveRateSnapshotStrict;
}

export function useLiveRateFeed({
  active,
  selectedThreadId,
  sourceToken,
  onSnapshot,
  retryGeneration = 0,
}: LiveRateFeedOptions,
dependencies: Partial<LiveRateFeedDependencies> = {},
) {
  const platform = dependencies.platform ?? desktopPlatform;
  const readInitialLiveRate = dependencies.readInitialLiveRate ?? readLiveRateSnapshotStrict;
  const lastSmoothedSnapshotRef = useRef<LiveRateSnapshot | null>(null);
  const lastDisplayBucketRef = useRef("");
  const previousSourceTokenRef = useRef<DashboardSourceToken | null>(null);
  const leaseControllerRef = useRef<LiveRateLeaseController | null | undefined>(undefined);
  let leaseController = leaseControllerRef.current;
  if (leaseController === undefined) {
    const ownerSession = tryCreateLiveRateOwnerSession("dashboard-live-rate");
    leaseController = ownerSession === null
      ? null
      : createLiveRateLeaseController((leaseId) => {
          void platform.stopLiveRateStream(leaseId);
        }, ownerSession);
    leaseControllerRef.current = leaseController;
  }

  useEffect(() => {
    const sourceChanged = !sameSourceToken(previousSourceTokenRef.current, sourceToken);
    previousSourceTokenRef.current = sourceToken;
    if (sourceChanged) {
      lastSmoothedSnapshotRef.current = null;
      lastDisplayBucketRef.current = "";
    }
    if (!active || sourceToken === null) {
      lastSmoothedSnapshotRef.current = null;
      lastDisplayBucketRef.current = "";
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    let externalEventGeneration = 0;
    const selected = selectedThreadId || null;

    const publishSnapshot = (liveRate: LiveRateSnapshot) => {
      const smoothed = smoothLiveRateSnapshot(liveRate, lastSmoothedSnapshotRef.current);
      const bucket = changedLiveRateDisplayBucket(lastDisplayBucketRef.current, smoothed);
      lastSmoothedSnapshotRef.current = smoothed;
      if (bucket === null) {
        return;
      }
      lastDisplayBucketRef.current = bucket;
      onSnapshot(smoothed);
    };

    if (leaseController === null) {
      publishSnapshot(liveRateStreamFailureSnapshot(
        selected,
        failedLiveRateStartResult("Live-rate owner epoch storage is unavailable"),
      ));
      return;
    }
    const leaseRequest = leaseController.begin();

    void platform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        externalEventGeneration += 1;
        publishSnapshot(liveRate);
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void (async () => {
      let accepted = false;
      try {
        const claimed = await platform.claimLiveRateOwnerSession(
          leaseRequest.ownerToken,
          leaseRequest.ownerSessionEpoch,
          sourceToken,
        );
        if (cancelled || !claimed) {
          return;
        }
        const startResult = await platform.startLiveRateStreamCommand({
          selectedThreadId: selected,
          controlsSelectedThread: true,
          subscriberOwnerToken: leaseRequest.ownerToken,
          ownerSessionEpoch: leaseRequest.ownerSessionEpoch,
          ownerGeneration: leaseRequest.ownerGeneration,
          sourceToken,
        });
        if (!startResult.ok || startResult.value === null) {
          if (!cancelled) {
            publishSnapshot(liveRateStreamFailureSnapshot(selected, startResult));
          }
          return;
        }
        accepted = leaseRequest.accept(startResult.value);
        if (!accepted) {
          return;
        }
        const liveRate = await readInitialLiveRate(selected, sourceToken);
        if (!cancelled && externalEventGeneration === 0) {
          publishSnapshot(liveRate);
        }
      } catch (error) {
        if (!cancelled && (!accepted || externalEventGeneration === 0)) {
          publishSnapshot(liveRateStreamFailureSnapshot(
            selected,
            failedLiveRateStartResult(error),
          ));
        }
      }
    })();

    return () => {
      cancelled = true;
      unlisten?.();
      leaseRequest.cancel();
    };
  }, [
    active,
    onSnapshot,
    platform,
    readInitialLiveRate,
    retryGeneration,
    selectedThreadId,
    sourceToken,
  ]);
}

function sameSourceToken(
  left: DashboardSourceToken | null,
  right: DashboardSourceToken | null,
): boolean {
  return left === right || (
    left !== null
    && right !== null
    && left.transitionGeneration === right.transitionGeneration
    && left.canonicalHomeKey === right.canonicalHomeKey
    && left.physicalHomeKey === right.physicalHomeKey
  );
}

function failedLiveRateStartResult(error: unknown): PlatformCommandResult<unknown> {
  return {
    ok: false,
    fallback: null,
    error: errorMessage(error),
  };
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim()) {
    return error.message;
  }
  if (typeof error === "string" && error.trim()) {
    return error;
  }
  return "Unknown live-rate stream failure";
}
