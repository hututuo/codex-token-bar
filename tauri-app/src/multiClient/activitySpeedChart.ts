export interface ActivityTrendPoint {
  bucketStart: number;
  value: { weightedOutput: number; coveredSeconds: number };
}

export function activityChartPoints(values: readonly ActivityTrendPoint[], now: number) {
  if (!Number.isFinite(now)) return [];
  let prior: number | undefined, segment = 0;
  return [...values].sort((a, b) => a.bucketStart - b.bucketStart).flatMap(point => {
    const rate = point.value.weightedOutput / point.value.coveredSeconds;
    if (!Number.isFinite(point.bucketStart) || point.bucketStart < now - 1800 || point.bucketStart > now
      || !Number.isFinite(point.value.coveredSeconds) || point.value.coveredSeconds <= 0
      || !Number.isFinite(rate) || rate < 0) return [];
    if (prior !== undefined && point.bucketStart - prior > 300) segment++;
    prior = point.bucketStart;
    return [{ bucketStart: point.bucketStart, rate, segment }];
  });
}
