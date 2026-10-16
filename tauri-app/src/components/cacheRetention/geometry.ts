import type { CacheRetentionPoint } from "../../domain/cacheRetention/types";

const LINEAR_LIMIT = 80;
export function retentionAxis(maxMinutes: number) {
  const max = Math.max(LINEAR_LIMIT, maxMinutes);
  const hasTail = max > LINEAR_LIMIT;
  const x = (minutes: number) => !hasTail
    ? Math.max(0, Math.min(1, minutes / LINEAR_LIMIT))
    : minutes <= LINEAR_LIMIT
      ? Math.max(0, minutes / LINEAR_LIMIT) * 0.82
      : 0.845 + 0.155 * Math.log(minutes / LINEAR_LIMIT) / Math.log(max / LINEAR_LIMIT);
  const ticks = Array.from({ length: 9 }, (_, i) => i * 10);
  if (hasTail) {
    for (const value of [120, 240, 480, 1440, 4320, 10080, 43200]) {
      if (value <= max && x(value) - x(ticks.at(-1)!) > 0.07) ticks.push(value);
    }
    if (x(max) - x(ticks.at(-1)!) > 0.06) ticks.push(max);
  }
  return { max, hasTail, x, ticks };
}

export function retentionDensity(points: CacheRetentionPoint[]) {
  const key = (point: CacheRetentionPoint) => `${Math.floor(point.gapMicroseconds / 10_000_000)}:${Math.floor((point.cached / point.input) / 0.05)}`;
  const counts = new Map<string, number>();
  for (const point of points) counts.set(key(point), (counts.get(key(point)) ?? 0) + 1);
  let max = 1;
  for (const count of counts.values()) max = Math.max(max, count);
  return { max, count: (point: CacheRetentionPoint) => counts.get(key(point)) ?? 1 };
}
