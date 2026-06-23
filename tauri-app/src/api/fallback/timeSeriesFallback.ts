import type { ActivityDay, RecentUsagePoint } from "../../types/usage";

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
  intervalMs = 300_000,
  pointCount = 289,
): RecentUsagePoint[] {
  const end = Math.floor(now.getTime() / intervalMs) * intervalMs;
  const start = end - (pointCount - 1) * intervalMs;
  return Array.from({ length: pointCount }, (_, index) => {
    const date = new Date(start + index * intervalMs);
    return {
      label: `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`,
      startUnix: Math.floor(date.getTime() / 1_000),
      tokens: 0,
      calls: 0,
      inputTokens: 0,
      cachedInputTokens: 0,
      cacheHitRate: null,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}
