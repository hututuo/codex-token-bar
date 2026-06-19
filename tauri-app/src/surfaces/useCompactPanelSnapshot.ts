import { useEffect, useState } from "react";
import { readFloatingPanelSnapshot } from "../api/client";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import type { FloatingPanelSnapshot } from "../types/dashboard";

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

    async function refreshSnapshot() {
      if (inFlight) {
        return;
      }

      inFlight = true;
      try {
        const next = await readFloatingPanelSnapshot();
        if (!cancelled) {
          setRawSnapshot(next);
        }
      } finally {
        inFlight = false;
      }
    }

    void refreshSnapshot();
    const interval = window.setInterval(() => {
      void refreshSnapshot();
    }, intervalMs);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [active, intervalMs]);

  return rawSnapshot;
}
