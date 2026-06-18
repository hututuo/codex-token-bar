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
    let liveRateInFlight = false;
    let streaming = false;
    let unlisten: (() => void) | null = null;
    let startupTimer = 0;
    const selected = selectedThreadId || null;

    async function refreshLiveRate() {
      if (liveRateInFlight) {
        return;
      }

      liveRateInFlight = true;
      try {
        const liveRate = await source.readLiveRateSnapshot(selected);
        if (!cancelled) {
          onSnapshotRef.current(liveRate);
        }
      } finally {
        liveRateInFlight = false;
      }
    }

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

    startupTimer = window.setTimeout(() => {
      void refreshLiveRate();
      void desktopPlatform.startLiveRateStream(selected).then((started) => {
        if (cancelled) {
          if (started) {
            void desktopPlatform.stopLiveRateStream();
          }
          return;
        }
        streaming = started;
      });
    }, 250);

    const interval = window.setInterval(() => {
      if (!streaming) {
        void refreshLiveRate();
      }
    }, 750);

    return () => {
      cancelled = true;
      unlisten?.();
      if (streaming) {
        void desktopPlatform.stopLiveRateStream();
      }
      window.clearTimeout(startupTimer);
      window.clearInterval(interval);
    };
  }, [active, selectedThreadId, source]);
}
