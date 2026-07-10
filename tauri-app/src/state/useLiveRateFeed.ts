import { useEffect, useRef } from "react";
import { resetLiveRateMonitor } from "../api/liveClient";
import {
  liveRateDisplayBucket,
  smoothLiveRateSnapshot,
} from "../components/liveRate/rateDisplay";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { PlatformCommandResult } from "../platform/desktopBridge";
import { desktopPlatform } from "../platform/desktop";
import type { LiveRateSnapshot } from "../types/dashboard";
import type { DashboardSourceToken } from "./dashboardSourceTransition";
import {
  createLiveRateLeaseController,
  type LiveRateLeaseController,
} from "./liveRateLease";
import { liveRateStreamFailureSnapshot } from "./liveRateStreamFailure";

interface LiveRateFeedOptions {
  active: boolean;
  selectedThreadId: string;
  source: Pick<DashboardDataSource, "readLiveRateSnapshot">;
  sourceToken: DashboardSourceToken | null;
  onSnapshot: (snapshot: LiveRateSnapshot) => void;
  retryGeneration?: number;
}

export function useLiveRateFeed({
  active,
  selectedThreadId,
  source,
  sourceToken,
  onSnapshot,
  retryGeneration = 0,
}: LiveRateFeedOptions) {
  const lastSmoothedSnapshotRef = useRef<LiveRateSnapshot | null>(null);
  const lastDisplayBucketRef = useRef("");
  const previousSourceTokenRef = useRef<DashboardSourceToken | null>(null);
  const leaseControllerRef = useRef<LiveRateLeaseController | null>(null);
  let leaseController = leaseControllerRef.current;
  if (leaseController === null) {
    leaseController = createLiveRateLeaseController((leaseId) => {
      void desktopPlatform.stopLiveRateStream(leaseId);
    });
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
    const selected = selectedThreadId || null;
    const leaseRequest = leaseController.begin();

    const publishSnapshot = (liveRate: LiveRateSnapshot) => {
      const smoothed = smoothLiveRateSnapshot(liveRate, lastSmoothedSnapshotRef.current);
      const bucket = liveRateDisplayBucket(smoothed);
      lastSmoothedSnapshotRef.current = smoothed;
      if (bucket === lastDisplayBucketRef.current) {
        return;
      }
      lastDisplayBucketRef.current = bucket;
      onSnapshot(smoothed);
    };

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        publishSnapshot(liveRate);
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void resetLiveRateMonitor().then(async () => {
      if (cancelled) {
        return null;
      }
      const startResult = await desktopPlatform.startLiveRateStreamCommand({
        selectedThreadId: selected,
        controlsSelectedThread: true,
        subscriberOwnerToken: leaseRequest.ownerToken,
        ownerGeneration: leaseRequest.ownerGeneration,
        sourceToken,
      });
      if (!startResult.ok || startResult.value === null) {
        if (!cancelled) {
          publishSnapshot(liveRateStreamFailureSnapshot(selected, startResult));
        }
        return null;
      }
      if (!leaseRequest.accept(startResult.value)) {
        return null;
      }
      return source.readLiveRateSnapshot(selected);
    }).then((liveRate) => {
      if (!cancelled) {
        if (liveRate !== null) {
          publishSnapshot(liveRate);
        }
      }
    }).catch((error) => {
      if (!cancelled) {
        publishSnapshot(liveRateStreamFailureSnapshot(selected, failedLiveRateStartResult(error)));
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
      leaseRequest.cancel();
    };
  }, [active, onSnapshot, retryGeneration, selectedThreadId, source, sourceToken]);
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
