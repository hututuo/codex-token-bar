import type { RecentUsagePoint } from "../../types/dashboard";

export type RecentChartRange = "24h" | "7d" | "30d";

export interface RecentUsageChartSeries {
  recentUsage24h: RecentUsagePoint[];
  recentUsage7d: RecentUsagePoint[];
  recentUsage30d: RecentUsagePoint[];
}

export interface SeriesVisibility {
  tokens: boolean;
  calls: boolean;
  cacheHitRate: boolean;
  fiveHourQuota: boolean;
  sevenDayQuota: boolean;
}

export interface Point {
  x: number;
  y: number;
}

export interface PreparedRecentChartData {
  range: RecentChartRange;
  title: string;
  subtitle: string;
  bucketSeconds: number;
  points: RecentUsagePoint[];
  maxTokens: number;
  maxCalls: number;
  tokenTotal: number;
  callTotal: number;
  cacheHitRate: number;
  carriedCacheHitRates: number[];
  latestFiveHourRemaining: number | null;
  latestSevenDayRemaining: number | null;
  hasCacheCalls: boolean;
  hasFiveHourQuota: boolean;
  hasSevenDayQuota: boolean;
  markerIndices: number[];
}

const RANGE_CONFIG: Record<RecentChartRange, { title: string; subtitle: string; bucketSeconds: number }> = {
  "24h": {
    title: "最近 24 小时",
    subtitle: "5 分钟粒度 · 5 分钟自动刷新",
    bucketSeconds: 5 * 60,
  },
  "7d": {
    title: "最近 7 天",
    subtitle: "1 小时粒度 · 5 分钟自动刷新",
    bucketSeconds: 60 * 60,
  },
  "30d": {
    title: "最近 30 天",
    subtitle: "6 小时粒度 · 5 分钟自动刷新",
    bucketSeconds: 6 * 60 * 60,
  },
};

export const DEFAULT_SERIES_VISIBILITY: SeriesVisibility = {
  tokens: true,
  calls: true,
  cacheHitRate: true,
  fiveHourQuota: true,
  sevenDayQuota: true,
};

export function prepareRecentChartData(
  range: RecentChartRange,
  series: RecentUsageChartSeries,
): PreparedRecentChartData {
  const config = RANGE_CONFIG[range];
  const points = pointsForRange(range, series);
  const tokenTotal = points.reduce((total, point) => total + point.tokens, 0);
  const callTotal = points.reduce((total, point) => total + point.calls, 0);
  const inputWeightedCacheHit = weightedCacheHitRate(points);
  const carriedCacheHitRates = carriedCacheRates(points);
  const fiveHourValues = points.map((point) => point.fiveHourRemainingPercent);
  const sevenDayValues = points.map((point) => point.sevenDayRemainingPercent);
  const last = points.length - 1;

  return {
    range,
    title: config.title,
    subtitle: config.subtitle,
    bucketSeconds: config.bucketSeconds,
    points,
    maxTokens: Math.max(1, ...points.map((point) => point.tokens)),
    maxCalls: Math.max(1, ...points.map((point) => point.calls)),
    tokenTotal,
    callTotal,
    cacheHitRate: inputWeightedCacheHit,
    carriedCacheHitRates,
    latestFiveHourRemaining: latestPresent(fiveHourValues),
    latestSevenDayRemaining: latestPresent(sevenDayValues),
    hasCacheCalls: points.some((point) => point.calls > 0 && point.cacheHitRate !== null),
    hasFiveHourQuota: fiveHourValues.some((value) => value !== null),
    hasSevenDayQuota: sevenDayValues.some((value) => value !== null),
    markerIndices:
      points.length > 1
        ? uniqueIndices([0, Math.floor(last / 4), Math.floor(last / 2), Math.floor((last * 3) / 4), last])
        : [],
  };
}

export function plotChartPoints(data: PreparedRecentChartData, width: number, plotHeight: number) {
  const step = width / Math.max(data.points.length - 1, 1);
  return {
    tokenPoints: data.points.map((point, index) => ({
      x: index * step,
      y: plotHeight - (point.tokens / data.maxTokens) * plotHeight,
    })),
    callPoints: data.points.map((point, index) => ({
      x: index * step,
      y: plotHeight - (point.calls / data.maxCalls) * plotHeight,
    })),
    cachePoints: data.points.map((_, index) => ({
      x: index * step,
      y: plotHeight - (data.carriedCacheHitRates[index] ?? 0) * plotHeight,
    })),
    fiveHourQuotaPoints: optionalQuotaPoints(data.points, "fiveHourRemainingPercent", width, plotHeight),
    sevenDayQuotaPoints: optionalQuotaPoints(data.points, "sevenDayRemainingPercent", width, plotHeight),
  };
}

export function smoothPath(points: Point[]): string {
  if (points.length === 0) {
    return "";
  }
  if (points.length <= 2) {
    return points
      .map((point, index) => `${index === 0 ? "M" : "L"} ${formatNumber(point.x)} ${formatNumber(point.y)}`)
      .join(" ");
  }

  const slopes = monotoneSlopes(points);
  if (slopes === null) {
    return polylinePath(points);
  }

  const commands = [`M ${formatNumber(points[0].x)} ${formatNumber(points[0].y)}`];
  for (let index = 0; index < points.length - 1; index += 1) {
    const start = points[index];
    const end = points[index + 1];
    const dx = end.x - start.x;
    if (dx <= Number.EPSILON) {
      commands.push(`L ${formatNumber(end.x)} ${formatNumber(end.y)}`);
      continue;
    }
    const controlDistance = dx / 3;
    commands.push(
      [
        "C",
        formatNumber(start.x + controlDistance),
        formatNumber(start.y + slopes[index] * controlDistance),
        formatNumber(end.x - controlDistance),
        formatNumber(end.y - slopes[index + 1] * controlDistance),
        formatNumber(end.x),
        formatNumber(end.y),
      ].join(" "),
    );
  }
  return commands.join(" ");
}

function polylinePath(points: Point[]): string {
  return points
    .map((point, index) => `${index === 0 ? "M" : "L"} ${formatNumber(point.x)} ${formatNumber(point.y)}`)
    .join(" ");
}

export function optionalSmoothPath(points: Array<Point | null>): string {
  const segments: string[] = [];
  let segment: Point[] = [];
  for (const point of points) {
    if (point === null) {
      if (segment.length > 0) {
        segments.push(smoothPath(segment));
        segment = [];
      }
      continue;
    }
    segment.push(point);
  }
  if (segment.length > 0) {
    segments.push(smoothPath(segment));
  }
  return segments.join(" ");
}

export function tokenAreaPath(points: Point[], width: number, plotHeight: number): string {
  const first = points[0];
  const last = points[points.length - 1];
  if (!first || !last) {
    return "";
  }
  return [
    `M ${formatNumber(first.x)} ${formatNumber(plotHeight)}`,
    `L ${formatNumber(first.x)} ${formatNumber(first.y)}`,
    smoothPath(points).replace(/^M [^LCSQTAZ]+ /, ""),
    `L ${formatNumber(width)} ${formatNumber(plotHeight)}`,
    `L ${formatNumber(last.x)} ${formatNumber(plotHeight)}`,
    "Z",
  ].join(" ");
}

export function hoverIndexForX(x: number, width: number, pointCount: number): number | null {
  if (pointCount === 0 || x < 0 || x > width) {
    return null;
  }
  const step = width / Math.max(pointCount - 1, 1);
  return clamp(Math.round(x / Math.max(step, 1)), 0, pointCount - 1);
}

export function percentText(value: number | null): string {
  if (value === null || !Number.isFinite(value)) {
    return "--";
  }
  return `${Math.round(value * 100)}%`;
}

function pointsForRange(range: RecentChartRange, series: RecentUsageChartSeries): RecentUsagePoint[] {
  switch (range) {
    case "24h":
      return series.recentUsage24h;
    case "7d":
      return series.recentUsage7d;
    case "30d":
      return series.recentUsage30d;
  }
}

function optionalQuotaPoints(
  points: RecentUsagePoint[],
  key: "fiveHourRemainingPercent" | "sevenDayRemainingPercent",
  width: number,
  plotHeight: number,
): Array<Point | null> {
  const step = width / Math.max(points.length - 1, 1);
  return points.map((point, index) => {
    const value = point[key];
    if (value === null) {
      return null;
    }
    return {
      x: index * step,
      y: plotHeight - clamp(value, 0, 1) * plotHeight,
    };
  });
}

function carriedCacheRates(points: RecentUsagePoint[]): number[] {
  let carried = points.find((point) => point.calls > 0 && point.cacheHitRate !== null)?.cacheHitRate ?? 0;
  return points.map((point) => {
    if (point.calls > 0 && point.cacheHitRate !== null) {
      carried = point.cacheHitRate;
    }
    return carried;
  });
}

function weightedCacheHitRate(points: RecentUsagePoint[]): number {
  let inputTokens = 0;
  let cachedInputTokens = 0;
  for (const point of points) {
    inputTokens += point.inputTokens;
    cachedInputTokens += point.cachedInputTokens;
  }
  return inputTokens === 0 ? 0 : cachedInputTokens / inputTokens;
}

function latestPresent(values: Array<number | null>): number | null {
  for (let index = values.length - 1; index >= 0; index -= 1) {
    const value = values[index];
    if (value !== null) {
      return value;
    }
  }
  return null;
}

function uniqueIndices(indices: number[]): number[] {
  return indices.filter((index, position) => indices.indexOf(index) === position);
}

function monotoneSlopes(points: Point[]): number[] | null {
  if (points.length <= 2) {
    return null;
  }

  const intervals: number[] = [];
  const deltas: number[] = [];
  for (let index = 0; index < points.length - 1; index += 1) {
    const dx = points[index + 1].x - points[index].x;
    if (dx <= Number.EPSILON) {
      return null;
    }
    intervals.push(dx);
    deltas.push((points[index + 1].y - points[index].y) / dx);
  }

  const slopes = Array(points.length).fill(0) as number[];
  slopes[0] = endpointSlope(intervals[0], intervals[1], deltas[0], deltas[1]);
  slopes[points.length - 1] = endpointSlope(
    intervals[intervals.length - 1],
    intervals[intervals.length - 2],
    deltas[deltas.length - 1],
    deltas[deltas.length - 2],
  );

  for (let index = 1; index < points.length - 1; index += 1) {
    const left = deltas[index - 1];
    const right = deltas[index];
    if (left === 0 || right === 0 || (left > 0) !== (right > 0)) {
      slopes[index] = 0;
      continue;
    }

    const leftInterval = intervals[index - 1];
    const rightInterval = intervals[index];
    const leftWeight = 2 * rightInterval + leftInterval;
    const rightWeight = rightInterval + 2 * leftInterval;
    slopes[index] = (leftWeight + rightWeight) / (leftWeight / left + rightWeight / right);
  }

  for (let index = 0; index < deltas.length; index += 1) {
    const delta = deltas[index];
    if (delta === 0) {
      slopes[index] = 0;
      slopes[index + 1] = 0;
      continue;
    }
    const alpha = slopes[index] / delta;
    const beta = slopes[index + 1] / delta;
    if (alpha < 0 || beta < 0) {
      if (alpha < 0) {
        slopes[index] = 0;
      }
      if (beta < 0) {
        slopes[index + 1] = 0;
      }
      continue;
    }
    const magnitude = alpha * alpha + beta * beta;
    if (magnitude > 9) {
      const scale = 3 / Math.sqrt(magnitude);
      slopes[index] = scale * alpha * delta;
      slopes[index + 1] = scale * beta * delta;
    }
  }

  return slopes;
}

function endpointSlope(
  edgeInterval: number,
  neighborInterval: number,
  edgeDelta: number,
  neighborDelta: number,
): number {
  if (edgeDelta === 0) {
    return 0;
  }
  const slope =
    ((2 * edgeInterval + neighborInterval) * edgeDelta - edgeInterval * neighborDelta) /
    (edgeInterval + neighborInterval);
  if ((slope > 0) !== (edgeDelta > 0)) {
    return 0;
  }
  if ((edgeDelta > 0) !== (neighborDelta > 0) && Math.abs(slope) > Math.abs(3 * edgeDelta)) {
    return 3 * edgeDelta;
  }
  return slope;
}

function formatNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}
