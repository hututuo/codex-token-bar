import type { ActivityDay, RecentUsagePoint } from "../../types/usage";
import {
  alignedTimeSeriesStarts,
  LONG_RECENT_INTERVAL_MS,
  LONG_RECENT_POINT_COUNT,
} from "../../timeSeriesTimeline";

export function emptyActivityDays(now: Date): ActivityDay[] {
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date(now);
    date.setDate(date.getDate() - (364 - index));
    return {
      date: date.toISOString().slice(0, 10),
      tokens: 0,
      calls: 0,
      cacheHitRate: 0,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}

export function emptyRecentUsage(
  now: Date,
  intervalMs = LONG_RECENT_INTERVAL_MS,
  pointCount = LONG_RECENT_POINT_COUNT,
): RecentUsagePoint[] {
  return alignedTimeSeriesStarts(now.getTime(), intervalMs, pointCount).map((startMs) => {
    const date = new Date(startMs);
    return {
      label: `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`,
      startUnix: Math.floor(date.getTime() / 1_000),
      tokens: 0,
      calls: 0,
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      cacheHitRate: null,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}
