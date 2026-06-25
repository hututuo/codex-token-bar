import { useEffect, useState } from "react";
import { readFloatingPanelSnapshot } from "../api/client";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import type { FloatingPanelSnapshot } from "../types/dashboard";

const FAST_LIVE_POLL_INTERVAL_MS = 250;
const IDLE_LIVE_POLL_INTERVAL_MS = 1_000;

interface CompactPanelSnapshotOptions {
  active: boolean;
  intervalMs: number;
}

export function useCompactPanelSnapshot({
  active,
  intervalMs,
}: CompactPanelSnapshotOptions): FloatingPanelSnapshot {
  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;
    let inFlight = false;
    let timer = 0;

    function scheduleNextPoll(delayMs: number) {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        void refreshSnapshot();
      }, delayMs);
    }

    async function refreshSnapshot() {
      if (inFlight) {
        return;
      }

      inFlight = true;
      let nextDelay = IDLE_LIVE_POLL_INTERVAL_MS;
      try {
        const next = await readFloatingPanelSnapshot();
        nextDelay = nextLivePollInterval(next);
        if (!cancelled) {
          setRawSnapshot(next);
        }
      } finally {
        inFlight = false;
        if (!cancelled) {
          scheduleNextPoll(nextDelay);
        }
      }
    }

    scheduleNextPoll(Math.min(intervalMs, FAST_LIVE_POLL_INTERVAL_MS));

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [active, intervalMs]);

  return rawSnapshot;
}

function nextLivePollInterval(snapshot: FloatingPanelSnapshot) {
  return snapshot.tokensPerSecond > 0.05
    ? FAST_LIVE_POLL_INTERVAL_MS
    : IDLE_LIVE_POLL_INTERVAL_MS;
}
