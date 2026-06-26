import { useEffect, useRef } from "react";
import { resetLiveRateMonitor } from "../api/liveClient";
import {
  liveRateDisplayBucket,
  smoothLiveRateSnapshot,
} from "../components/liveRate/rateDisplay";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import { desktopPlatform } from "../platform/desktop";
import type { LiveRateSnapshot } from "../types/dashboard";

interface LiveRateFeedOptions {
  active: boolean;
  selectedThreadId: string;
  source: Pick<DashboardDataSource, "readLiveRateSnapshot">;
  onSnapshot: (snapshot: LiveRateSnapshot) => void;
}

export function useLiveRateFeed({
  active,
  selectedThreadId,
  source,
  onSnapshot,
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

    void resetLiveRateMonitor().finally(() => {
      if (!cancelled) {
        void desktopPlatform.startLiveRateStream(selected, true);
      }
    }).then(() => source.readLiveRateSnapshot(selected)).then((liveRate) => {
      if (!cancelled) {
        publishSnapshot(liveRate);
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
      void desktopPlatform.stopLiveRateStream();
    };
  }, [active, selectedThreadId, source]);
}
