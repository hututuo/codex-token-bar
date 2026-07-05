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
import { liveRateStreamFailureSnapshot } from "./liveRateStreamFailure";

interface LiveRateFeedOptions {
  active: boolean;
  selectedThreadId: string;
  source: Pick<DashboardDataSource, "readLiveRateSnapshot">;
  onSnapshot: (snapshot: LiveRateSnapshot) => void;
  retryGeneration?: number;
}

export function useLiveRateFeed({
  active,
  selectedThreadId,
  source,
  onSnapshot,
  retryGeneration = 0,
}: LiveRateFeedOptions) {
  const onSnapshotRef = useRef(onSnapshot);
  const lastSmoothedSnapshotRef = useRef<LiveRateSnapshot | null>(null);
  const lastDisplayBucketRef = useRef("");

  useEffect(() => {
    onSnapshotRef.current = onSnapshot;
  }, [onSnapshot]);

  useEffect(() => {
    if (!active) {
      lastSmoothedSnapshotRef.current = null;
      lastDisplayBucketRef.current = "";
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    const selected = selectedThreadId || null;

    const publishSnapshot = (liveRate: LiveRateSnapshot) => {
      const smoothed = smoothLiveRateSnapshot(liveRate, lastSmoothedSnapshotRef.current);
      const bucket = liveRateDisplayBucket(smoothed);
      lastSmoothedSnapshotRef.current = smoothed;
      if (bucket === lastDisplayBucketRef.current) {
        return;
      }
      lastDisplayBucketRef.current = bucket;
      onSnapshotRef.current(smoothed);
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
      const startResult = await desktopPlatform.startLiveRateStreamCommand(selected, true);
      if (!startResult.ok) {
        publishSnapshot(liveRateStreamFailureSnapshot(selected, startResult));
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
      void desktopPlatform.stopLiveRateStream();
    };
  }, [active, retryGeneration, selectedThreadId, source]);
}

function failedLiveRateStartResult(error: unknown): PlatformCommandResult<boolean> {
  return {
    ok: false,
    fallback: false,
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
