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

export function emptyRecentUsage(now: Date): RecentUsagePoint[] {
  const end = Math.floor(now.getTime() / 300_000) * 300_000;
  const start = end - 24 * 60 * 60 * 1_000;
  return Array.from({ length: 289 }, (_, index) => {
    const date = new Date(start + index * 300_000);
    return {
      label: `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`,
      tokens: 0,
      calls: 0,
      cacheHitRate: null,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    };
  });
}
