import { useCallback, useEffect, useRef, useState } from "react";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { readUsageSummarySnapshot } from "../api/dashboardClient";
import { readLiveRateSnapshot } from "../api/liveClient";
import { desktopPlatform } from "../platform/desktop";
import type { FloatingPanelSnapshot, LiveRateSnapshot, UsageSummarySnapshot } from "../types/dashboard";
import {
  LIVE_USAGE_ACTIVITY_HOLD_MS,
  liveRateHasUsageRefreshActivity,
  usageRefreshIntervalMs,
} from "../utils/usageRefreshCadence";
import {
  disabledFloatingLiveSnapshot,
  floatingSnapshotForLiveRate,
  liveRateStreamStartFailureSnapshot,
  mergeFloatingUsageSummary,
} from "./compactPanelSnapshotModel";

interface CompactPanelSnapshotOptions {
  active: boolean;
  liveRateEnabled: boolean;
}

const COMPACT_USAGE_SUMMARY_REFRESH_INTERVAL_MS = 60_000;

export function useCompactPanelSnapshot({
  active,
  liveRateEnabled,
}: CompactPanelSnapshotOptions): FloatingPanelSnapshot {
  const [rawSnapshot, setRawSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const [lastLiveActivityAtMs, setLastLiveActivityAtMs] = useState(0);
  const lastLiveActivityAtMsRef = useRef(0);
  const usageSummaryRef = useRef<UsageSummarySnapshot | null>(null);

  const markLiveUsageActivity = useCallback((liveRate: LiveRateSnapshot) => {
    if (!liveRateHasUsageRefreshActivity(liveRate)) {
      return;
    }

    const nowMs = Date.now();
    lastLiveActivityAtMsRef.current = nowMs;
    setLastLiveActivityAtMs((current) => {
      if (current > 0 && nowMs - current < LIVE_USAGE_ACTIVITY_HOLD_MS) {
        return current;
      }
      return nowMs;
    });
  }, []);

  useEffect(() => {
    if (!active) {
      usageSummaryRef.current = null;
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
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
    const intervalMs = usageRefreshIntervalMs({
      baselineIntervalMs: COMPACT_USAGE_SUMMARY_REFRESH_INTERVAL_MS,
      lastLiveActivityAtMs,
    });
    const timer = setInterval(refreshUsageSummary, intervalMs);

    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [active, lastLiveActivityAtMs]);

  useEffect(() => {
    if (lastLiveActivityAtMs <= 0) {
      return;
    }

    const timer = setTimeout(() => {
      const latestActivityAtMs = lastLiveActivityAtMsRef.current;
      if (
        latestActivityAtMs > 0
        && Date.now() - latestActivityAtMs < LIVE_USAGE_ACTIVITY_HOLD_MS
      ) {
        setLastLiveActivityAtMs(latestActivityAtMs);
        return;
      }

      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
    }, LIVE_USAGE_ACTIVITY_HOLD_MS);

    return () => {
      clearTimeout(timer);
    };
  }, [lastLiveActivityAtMs]);

  useEffect(() => {
    if (!active || !liveRateEnabled) {
      lastLiveActivityAtMsRef.current = 0;
      setLastLiveActivityAtMs(0);
      setRawSnapshot(disabledFloatingLiveSnapshot);
      return;
    }

    let cancelled = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onLiveRateSnapshot((liveRate) => {
      if (!cancelled) {
        markLiveUsageActivity(liveRate);
        setRawSnapshot(floatingSnapshotForLiveRate(liveRate, usageSummaryRef.current));
      }
    }).then((listener) => {
      if (cancelled) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    void desktopPlatform.startLiveRateStreamCommand(null, false).then((result) => {
      if (cancelled || (result.ok && result.value)) {
        return;
      }
      const message = result.ok ? "实时速率流暂不可用" : result.error;
      setRawSnapshot(floatingSnapshotForLiveRate(
        liveRateStreamStartFailureSnapshot(message),
        usageSummaryRef.current,
      ));
    });
    void readLiveRateSnapshot(null).then((liveRate) => {
      if (!cancelled) {
        markLiveUsageActivity(liveRate);
        setRawSnapshot(floatingSnapshotForLiveRate(liveRate, usageSummaryRef.current));
      }
    });

    return () => {
      cancelled = true;
      unlisten?.();
      void desktopPlatform.stopLiveRateStream();
    };
  }, [active, liveRateEnabled, markLiveUsageActivity]);

  return rawSnapshot;
}
