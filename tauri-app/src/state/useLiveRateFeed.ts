import { useEffect, useRef } from "react";
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

  useEffect(() => {
    onSnapshotRef.current = onSnapshot;
  }, [onSnapshot]);

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;
    const selected = selectedThreadId || null;

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        onSnapshotRef.current(liveRate);
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void desktopPlatform.startLiveRateStream(selected, true);
    void source.readLiveRateSnapshot(selected).then((liveRate) => {
      if (!cancelled) {
        onSnapshotRef.current(liveRate);
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
      void desktopPlatform.stopLiveRateStream();
    };
  }, [active, selectedThreadId, source]);
}
