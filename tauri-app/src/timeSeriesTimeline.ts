export const LONG_RECENT_INTERVAL_MS = 5 * 60 * 1_000;
export const LONG_RECENT_POINT_COUNT = 30 * 24 * 12;

export function alignedTimeSeriesStarts(
  nowMs: number,
  intervalMs: number,
  pointCount: number,
): number[] {
  const end = Math.floor(nowMs / intervalMs) * intervalMs;
  const start = end - (pointCount - 1) * intervalMs;
  return Array.from({ length: pointCount }, (_, index) => start + index * intervalMs);
}

export function longRecentStarts(nowMs: number): number[] {
  return alignedTimeSeriesStarts(nowMs, LONG_RECENT_INTERVAL_MS, LONG_RECENT_POINT_COUNT);
}
