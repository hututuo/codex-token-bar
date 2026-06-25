import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { LiveRateSnapshot } from "../types/dashboard";

const FAST_LIVE_POLL_INTERVAL_MS = 250;
const IDLE_LIVE_POLL_INTERVAL_MS = 1_000;

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
  const nextIntervalRef = useRef(FAST_LIVE_POLL_INTERVAL_MS);

  useEffect(() => {
    onSnapshotRef.current = onSnapshot;
  }, [onSnapshot]);

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;
    let liveRateInFlight = false;
    let timer = 0;
    const selected = selectedThreadId || null;

    function scheduleNextPoll(delayMs: number) {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        void refreshLiveRate();
      }, delayMs);
    }

    async function refreshLiveRate() {
      if (liveRateInFlight) {
        return;
      }

      liveRateInFlight = true;
      try {
        const liveRate = await source.readLiveRateSnapshot(selected);
        if (!cancelled) {
          nextIntervalRef.current = nextLivePollInterval(liveRate);
          onSnapshotRef.current(liveRate);
        }
      } finally {
        liveRateInFlight = false;
        if (!cancelled) {
          scheduleNextPoll(nextIntervalRef.current);
        }
      }
    }

    scheduleNextPoll(FAST_LIVE_POLL_INTERVAL_MS);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [active, selectedThreadId, source]);
}

function nextLivePollInterval(snapshot: LiveRateSnapshot) {
  return snapshot.tokensPerSecond > 0.05 || snapshot.selectedTokensPerSecond > 0.05
    ? FAST_LIVE_POLL_INTERVAL_MS
    : IDLE_LIVE_POLL_INTERVAL_MS;
}
