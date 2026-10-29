export interface ActivityTrendPoint {
  bucketStart: number;
  value: { weightedOutput: number; coveredSeconds: number };
}

export function activityChartPoints(values: readonly ActivityTrendPoint[], now: number, windowSeconds = 1800, bucketSeconds = 60) {
  if (!Number.isFinite(now) || ![1800,86400].includes(windowSeconds) || ![30,60].includes(bucketSeconds)) return [];
  let prior: number | undefined, segment = 0;
  return [...values].sort((a, b) => a.bucketStart - b.bucketStart).flatMap(point => {
    const rate = point.value.weightedOutput / point.value.coveredSeconds;
    if (!Number.isFinite(point.bucketStart) || point.bucketStart < now - windowSeconds || point.bucketStart > now
      || !Number.isFinite(point.value.coveredSeconds) || point.value.coveredSeconds <= 0
      || !Number.isFinite(rate) || rate < 0 || (rate > 0 && rate <= 1e-9)) return [];
    if (prior !== undefined && point.bucketStart - prior > bucketSeconds) segment++;
    prior = point.bucketStart;
    return [{ bucketStart: point.bucketStart, rate, segment }];
  });
}
