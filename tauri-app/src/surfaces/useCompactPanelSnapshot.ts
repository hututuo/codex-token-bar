import { useEffect, useRef, useState } from "react";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { readUsageSummarySnapshot } from "../api/dashboardClient";
import { readLiveRateSnapshot } from "../api/liveClient";
import { desktopPlatform } from "../platform/desktop";
import type { FloatingPanelSnapshot, UsageSummarySnapshot } from "../types/dashboard";
import {
  disabledFloatingLiveSnapshot,
  floatingSnapshotForLiveRate,
  mergeFloatingUsageSummary,
} from "./compactPanelSnapshotModel";

interface CompactPanelSnapshotOptions {
  active: boolean;
  liveRateEnabled: boolean;
}

export function useCompactPanelSnapshot({
  active,
  liveRateEnabled,
}: CompactPanelSnapshotOptions): FloatingPanelSnapshot {
  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const usageSummaryRef = useRef<UsageSummarySnapshot | null>(null);

  useEffect(() => {
    if (!active) {
      usageSummaryRef.current = null;
      setRawSnapshot(emptyFloatingPanelSnapshot);
      return;
    }

    let cancelled = false;
    const refreshUsageSummary = async () => {
      const summary = await readUsageSummarySnapshot();
      if (!cancelled && summary) {
        usageSummaryRef.current = summary;
        setRawSnapshot((current) => mergeFloatingUsageSummary(current, summary));
      }
    };

    void refreshUsageSummary();
    const timer = setInterval(refreshUsageSummary, 60_000);

    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [active]);

  useEffect(() => {
    if (!active || !liveRateEnabled) {
      setRawSnapshot(disabledFloatingLiveSnapshot);
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        setRawSnapshot(floatingSnapshotForLiveRate(liveRate, usageSummaryRef.current));
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void desktopPlatform.startLiveRateStream(null, false);
    void readLiveRateSnapshot(null).then((liveRate) => {
      if (!cancelled) {
        setRawSnapshot(floatingSnapshotForLiveRate(liveRate, usageSummaryRef.current));
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
      void desktopPlatform.stopLiveRateStream();
    };
  }, [active, liveRateEnabled]);

  return rawSnapshot;
}
