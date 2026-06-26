import { useEffect, useState } from "react";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { readLiveRateSnapshot } from "../api/liveClient";
import { desktopPlatform } from "../platform/desktop";
import type { FloatingPanelSnapshot, LiveRateSnapshot } from "../types/dashboard";

interface CompactPanelSnapshotOptions {
  active: boolean;
}

export function useCompactPanelSnapshot({
  active,
}: CompactPanelSnapshotOptions): FloatingPanelSnapshot {
  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);

  useEffect(() => {
    if (!active) {
      setRawSnapshot(emptyFloatingPanelSnapshot);
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        setRawSnapshot(floatingSnapshotFromLiveRate(liveRate));
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
        setRawSnapshot(floatingSnapshotFromLiveRate(liveRate));
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
      void desktopPlatform.stopLiveRateStream();
    };
  }, [active]);

  return rawSnapshot;
}

function floatingSnapshotFromLiveRate(snapshot: LiveRateSnapshot): FloatingPanelSnapshot {
  return {
    ...emptyFloatingPanelSnapshot,
    tokensPerSecond: snapshot.tokensPerSecond,
    maxTokensPerSecond: snapshot.maxTokensPerSecond,
    totalTokensLabel: `总 ${compactTokens(snapshot.totalTokens)}`,
    todayTokensLabel: `今 ${compactTokens(snapshot.totalTokensToday)}`,
    requestsLabel: `次 ${snapshot.requestsToday}`,
    unread: snapshot.unreadSummary.active,
    unreadSummary: snapshot.unreadSummary,
  };
}

function compactTokens(value: number): string {
  if (value >= 100_000_000) {
    return `${(value / 100_000_000).toFixed(1)}亿`;
  }
  if (value >= 10_000) {
    return `${(value / 10_000).toFixed(1)}万`;
  }
  return String(Math.max(0, Math.round(value)));
}
