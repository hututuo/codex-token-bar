import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
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

    startupTimer = window.setTimeout(() => {
      void refreshLiveRate();
    }, 250);

    const interval = window.setInterval(() => {
      void refreshLiveRate();
    }, 500);

    return () => {
      cancelled = true;
      window.clearTimeout(startupTimer);
      window.clearInterval(interval);
    };
  }, [active, selectedThreadId, source]);
}
