import type { RecentUsagePoint } from "../../types/dashboard";
import {
  modelAwareAPICostUSD,
  officialAPICostUSD as calculateOfficialAPICostUSD,
  type ModelTokenCostRow,
  type OfficialAPIPriceModel,
} from "../../settings/quotaPriceModel.ts";
import type { SharedAccountAttributionResult } from "../sharedAccountAttribution/model.ts";

export type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel.ts";

export type RecentChartRange = "24h" | "7d" | "30d";

export interface RecentChartScrollLayout {
  isHorizontal: boolean;
  viewportWidth: number;
  contentWidth: number;
  latestScrollLeft: number;
  windowCount: number;
  className: string;
}

export interface RecentUsageChartSeries {
  recentUsage24h: RecentUsagePoint[];
  recentUsage7d: RecentUsagePoint[];
  recentUsage30d: RecentUsagePoint[];
}

export const RECENT_CHART_24H_VIEWPORT_SECONDS = 24 * 60 * 60;

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
  observedCacheHitRates: Array<number | null>;
  latestFiveHourRemaining: number | null;
  latestSevenDayRemaining: number | null;
  hasCacheCalls: boolean;
  hasFiveHourQuota: boolean;
  hasSevenDayQuota: boolean;
  markerIndices: number[];
}

export interface QuotaEstimateWindowVisibility {
  fiveHour: boolean;
  sevenDay: boolean;
}

export interface RecentChartTimeMarker {
  index: number;
  x: number;
  label: string;
  kind: "day" | "time";
}

export type QuotaConsumptionConfidence = "measured" | "insufficientQuotaMovement" | "noTokenUsage";

export interface QuotaConsumptionEstimate {
  selectedCostUSD: number;
  impliedWindowBudgetUSD: number | null;
  quotaDropPercent: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  calls: number;
  cacheHitRate: number;
  quotaDropAvailable: boolean;
  comparisonBreakdown: ModelTokenCostRow["breakdown"] & { totalTokens: number };
  comparisonStartUnix: number | null;
  comparisonEndUnix: number | null;
  confidence: QuotaConsumptionConfidence;
}

export interface QuotaConsumptionSelection {
  startIndex: number;
  endIndex: number;
  bucketCount: number;
  startUnix: number;
  endUnix: number;
  priceModel: OfficialAPIPriceModel;
  selectedCostUSD: number;
  totalTokens: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  calls: number;
  cacheHitRate: number;
  modelBreakdowns: ModelTokenCostRow[];
  sevenDayModelBreakdowns: ModelTokenCostRow[];
  fiveHour: QuotaConsumptionEstimate;
  sevenDay: QuotaConsumptionEstimate;
  sevenDayToFiveHourBudgetRatio: number | null;
  hasDivergentBudgetRatio: boolean;
}

export type QuotaSelectionAttributionState =
  | "withinTolerance"
  | "suspectedNonLocalUsage"
  | "localEstimateExceedsAccountDrop"
  | "provisional";

export interface QuotaSelectionAttributionResult {
  state: QuotaSelectionAttributionState;
  accountDropPercent: number;
  localSharePercent: number;
  nonLocalDifferencePercent: number;
  localComparableCostUSD: number;
  radarSevenDayTotalUSD: number;
  allowsAttributionConclusion: boolean;
}

export interface QuotaSelectionState {
  startIndex: number | null;
  fixedEndIndex: number | null;
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

export function recentChartScrollLayout(
  range: RecentChartRange,
  pointCount = 0,
  bucketSeconds = 0,
  viewportWidth = 980,
): RecentChartScrollLayout {
  const safeViewportWidth = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 980;
  if (range !== "24h") {
    return {
      isHorizontal: false,
      viewportWidth: safeViewportWidth,
      contentWidth: safeViewportWidth,
      latestScrollLeft: 0,
      windowCount: 1,
      className: "recent-chart-scroll",
    };
  }

  const intervalCount = Math.max(0, pointCount - 1);
  const safeBucketSeconds = Number.isFinite(bucketSeconds) && bucketSeconds > 0 ? bucketSeconds : 5 * 60;
  const viewportIntervalCount = Math.max(1, RECENT_CHART_24H_VIEWPORT_SECONDS / safeBucketSeconds);
  const rawContentWidth = intervalCount > 0
    ? Math.round((intervalCount / viewportIntervalCount) * safeViewportWidth)
    : safeViewportWidth;
  const contentWidth = Math.max(safeViewportWidth, rawContentWidth);
  const windowCount = Math.max(1, Math.ceil(Math.max(intervalCount, 1) / viewportIntervalCount));

  return {
    isHorizontal: contentWidth > safeViewportWidth,
    viewportWidth: safeViewportWidth,
    contentWidth,
    latestScrollLeft: Math.max(0, contentWidth - safeViewportWidth),
    windowCount,
    className: "recent-chart-scroll recent-chart-scroll--horizontal",
  };
}

export function prepareRecentChartData(
  range: RecentChartRange,
  series: RecentUsageChartSeries,
): PreparedRecentChartData {
  const config = RANGE_CONFIG[range];
  const points = pointsForRange(range, series);
  const tokenTotal = points.reduce((total, point) => total + point.tokens, 0);
  const callTotal = points.reduce((total, point) => total + point.calls, 0);
  const inputWeightedCacheHit = weightedCacheHitRate(points);
  const observedCacheHitRates = observedCacheRates(points);
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
    observedCacheHitRates,
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

export function quotaEstimateWindowVisibility(
  data: Pick<PreparedRecentChartData, "hasFiveHourQuota" | "hasSevenDayQuota">,
): QuotaEstimateWindowVisibility {
  return {
    fiveHour: data.hasFiveHourQuota,
    sevenDay: data.hasSevenDayQuota,
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
    cachePoints: data.points.map((_, index) => {
      const rate = data.observedCacheHitRates[index];
      return rate === null || rate === undefined
        ? null
        : { x: index * step, y: plotHeight - rate * plotHeight };
    }),
    fiveHourQuotaPoints: optionalQuotaPoints(data.points, "fiveHourRemainingPercent", width, plotHeight),
    sevenDayQuotaPoints: optionalQuotaPoints(data.points, "sevenDayRemainingPercent", width, plotHeight),
  };
}

export function recentChartTimeMarkers(data: PreparedRecentChartData, chartWidth: number): RecentChartTimeMarker[] {
  const pointCount = data.points.length;
  if (pointCount === 0) {
    return [];
  }

  const safeChartWidth = Number.isFinite(chartWidth) && chartWidth > 0 ? chartWidth : 980;
  if (data.range !== "24h") {
    return data.markerIndices.flatMap((index) => {
      const point = data.points[index];
      if (!point) {
        return [];
      }
      return [{
        index,
        x: markerX(index, pointCount, safeChartWidth),
        label: formatLocalMonthDay(point.startUnix),
        kind: "time" as const,
      }];
    });
  }

  const markers: RecentChartTimeMarker[] = [];
  let previousDayKey: string | null = null;
  data.points.forEach((point, index) => {
    const dayKey = localDayKey(point.startUnix);
    if (dayKey === previousDayKey) {
      return;
    }
    previousDayKey = dayKey;
    markers.push({
      index,
      x: markerX(index, pointCount, safeChartWidth),
      label: formatLocalMonthDay(point.startUnix),
      kind: "day",
    });
  });
  return markers;
}

export function recentChartVisibleWindowLabel(
  data: PreparedRecentChartData,
  chartWidth: number,
  scrollLeft: number,
  viewportWidth: number,
): string | null {
  if (data.range !== "24h" || data.points.length === 0) {
    return null;
  }
  const safeChartWidth = Number.isFinite(chartWidth) && chartWidth > 0 ? chartWidth : 980;
  const safeViewportWidth = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 980;
  const maxScrollLeft = Math.max(0, safeChartWidth - safeViewportWidth);
  const safeScrollLeft = Number.isFinite(scrollLeft) ? clamp(scrollLeft, 0, maxScrollLeft) : 0;
  const lastIndex = data.points.length - 1;
  const startIndex = hoverIndexForX(safeScrollLeft, safeChartWidth, data.points.length) ?? 0;
  const viewportBucketCount = Math.max(1, Math.round(RECENT_CHART_24H_VIEWPORT_SECONDS / data.bucketSeconds));
  const endIndex = clamp(startIndex + viewportBucketCount - 1, startIndex, lastIndex);
  const start = data.points[startIndex].startUnix;
  const end = data.points[endIndex].startUnix + data.bucketSeconds;
  return `${formatLocalMonthDayHour(start)} - ${formatLocalMonthDayHour(end)}`;
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
        segments.push(optionalSegmentPath(segment));
        segment = [];
      }
      continue;
    }
    segment.push(point);
  }
  if (segment.length > 0) {
    segments.push(optionalSegmentPath(segment));
  }
  return segments.join(" ");
}

function optionalSegmentPath(points: Point[]): string {
  if (points.length !== 1) {
    return smoothPath(points);
  }
  const point = points[0];
  return `M ${formatNumber(point.x)} ${formatNumber(point.y)} L ${formatNumber(point.x + 0.01)} ${formatNumber(point.y)}`;
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

export function clickQuotaSelection(
  state: QuotaSelectionState,
  index: number,
  validCount: number,
): QuotaSelectionState {
  if (validCount <= 0 || index < 0 || index >= validCount) {
    return state;
  }
  if (state.startIndex === null || state.fixedEndIndex !== null) {
    return { startIndex: index, fixedEndIndex: null };
  }
  return { startIndex: state.startIndex, fixedEndIndex: index };
}

export function activeQuotaSelectionEndIndex(
  state: QuotaSelectionState,
  hoveredIndex: number | null,
  fallbackEndIndex: number,
): number | null {
  return state.fixedEndIndex ?? hoveredIndex ?? state.startIndex ?? fallbackEndIndex;
}

export function clampQuotaSelection(state: QuotaSelectionState, validCount: number): QuotaSelectionState {
  if (validCount <= 0 || state.startIndex === null || state.startIndex < 0 || state.startIndex >= validCount) {
    return { startIndex: null, fixedEndIndex: null };
  }
  if (state.fixedEndIndex !== null && (state.fixedEndIndex < 0 || state.fixedEndIndex >= validCount)) {
    return { startIndex: state.startIndex, fixedEndIndex: null };
  }
  return state;
}

export function quotaConsumptionSelection(
  data: PreparedRecentChartData,
  startIndex: number,
  endIndex: number,
  priceModel: OfficialAPIPriceModel,
): QuotaConsumptionSelection | null {
  if (data.points.length === 0) {
    return null;
  }
  const lower = Math.max(0, Math.min(startIndex, endIndex));
  const upper = Math.min(data.points.length - 1, Math.max(startIndex, endIndex));
  if (lower > upper) {
    return null;
  }

  const selectedPoints = data.points.slice(lower, upper + 1);
  const breakdown = combineTokenBreakdown(selectedPoints);
  const selectedCostUSD = modelAwareAPICostUSD(
    selectedPoints.flatMap((point) => point.modelBreakdowns ?? []),
    breakdown,
    priceModel,
  ).costUSD;
  const fiveHourDrop = quotaDropResolution(selectedPoints.map((point) => point.fiveHourRemainingPercent));
  const sevenDayDrop = quotaDropResolution(selectedPoints.map((point) => point.sevenDayRemainingPercent));
  const fiveHourComparisonPoints = fiveHourDrop.comparisonStartOffset === null
    ? []
    : selectedPoints.slice(fiveHourDrop.comparisonStartOffset);
  const sevenDayComparisonPoints = sevenDayDrop.comparisonStartOffset === null
    ? []
    : selectedPoints.slice(sevenDayDrop.comparisonStartOffset);
  const fiveHourComparisonBreakdown = combineTokenBreakdown(fiveHourComparisonPoints);
  const sevenDayComparisonBreakdown = combineTokenBreakdown(sevenDayComparisonPoints);
  const fiveHourComparisonCost = modelAwareAPICostUSD(
    fiveHourComparisonPoints.flatMap((point) => point.modelBreakdowns ?? []),
    fiveHourComparisonBreakdown,
    priceModel,
  ).costUSD;
  const sevenDayModelBreakdowns = sevenDayComparisonPoints.flatMap((point) => point.modelBreakdowns ?? []);
  const sevenDayComparisonCost = modelAwareAPICostUSD(
    sevenDayModelBreakdowns,
    sevenDayComparisonBreakdown,
    priceModel,
  ).costUSD;
  const fiveHour = quotaConsumptionEstimate(
    breakdown,
    fiveHourDrop,
    selectedCostUSD,
    fiveHourComparisonCost,
    fiveHourComparisonBreakdown,
    selectedPoints,
    data.bucketSeconds,
  );
  const sevenDay = quotaConsumptionEstimate(
    breakdown,
    sevenDayDrop,
    selectedCostUSD,
    sevenDayComparisonCost,
    sevenDayComparisonBreakdown,
    selectedPoints,
    data.bucketSeconds,
  );
  const ratio = fiveHour.impliedWindowBudgetUSD && sevenDay.impliedWindowBudgetUSD
    ? sevenDay.impliedWindowBudgetUSD / fiveHour.impliedWindowBudgetUSD
    : null;

  return {
    startIndex: lower,
    endIndex: upper,
    bucketCount: upper - lower + 1,
    startUnix: data.points[lower].startUnix,
    endUnix: data.points[upper].startUnix + data.bucketSeconds,
    priceModel,
    selectedCostUSD: fiveHour.selectedCostUSD,
    totalTokens: breakdown.totalTokens,
    inputTokens: breakdown.inputTokens,
    cachedInputTokens: breakdown.cachedInputTokens,
    outputTokens: breakdown.outputTokens,
    calls: breakdown.calls,
    cacheHitRate: breakdown.cacheHitRate,
    modelBreakdowns: selectedPoints.flatMap((point) => point.modelBreakdowns ?? []),
    sevenDayModelBreakdowns,
    fiveHour,
    sevenDay,
    sevenDayToFiveHourBudgetRatio: ratio,
    hasDivergentBudgetRatio: ratio !== null && (ratio < 4.5 || ratio > 7.5),
  };
}

export function quotaSelectionDurationText(
  selection: Pick<QuotaConsumptionSelection, "startUnix" | "endUnix">,
): string {
  const totalSeconds = Math.max(Math.round(selection.endUnix - selection.startUnix), 0);
  if (totalSeconds < 60) {
    return `持续 ${totalSeconds}秒`;
  }

  const totalMinutes = Math.floor(totalSeconds / 60);
  const days = Math.floor(totalMinutes / (24 * 60));
  const hours = Math.floor((totalMinutes % (24 * 60)) / 60);
  const minutes = totalMinutes % 60;
  const parts: string[] = [];
  if (days > 0) parts.push(`${days}天`);
  if (hours > 0) parts.push(`${hours}小时`);
  if (minutes > 0 || parts.length === 0) parts.push(`${minutes}分钟`);
  return `持续 ${parts.join("")}`;
}

function pointsForRange(range: RecentChartRange, series: RecentUsageChartSeries): RecentUsagePoint[] {
  let points: RecentUsagePoint[];
  switch (range) {
    case "24h":
      points = series.recentUsage24h;
      break;
    case "7d":
      points = series.recentUsage7d;
      break;
    case "30d":
      points = series.recentUsage30d;
      break;
  }
  return points.map(normalizeRecentUsagePoint);
}

function normalizeRecentUsagePoint(point: RecentUsagePoint): RecentUsagePoint {
  const inputTokens = finiteNonnegative(point.inputTokens);
  const cachedInputTokens = Math.min(finiteNonnegative(point.cachedInputTokens), inputTokens);
  const cacheHitRate = point.cacheHitRate === null || !Number.isFinite(point.cacheHitRate)
    ? null
    : inputTokens === 0 ? 0 : cachedInputTokens / inputTokens;
  return {
    ...point,
    inputTokens,
    cachedInputTokens,
    cacheHitRate,
  };
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
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

function observedCacheRates(points: RecentUsagePoint[]): Array<number | null> {
  return points.map((point) => point.calls > 0 ? point.cacheHitRate : null);
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

function combineTokenBreakdown(points: RecentUsagePoint[]) {
  const inputTokens = points.reduce((total, point) => total + point.inputTokens, 0);
  const cachedInputTokens = points.reduce((total, point) => total + point.cachedInputTokens, 0);
  // Native exact history exposes output tokens directly. Do not reinterpret
  // total-minus-input as output: total may include non-billable or separately
  // classified token dimensions.
  const outputTokens = points.reduce((total, point) => total + finiteNonnegative(point.outputTokens), 0);
  const calls = points.reduce((total, point) => total + point.calls, 0);
  const costUSD = officialAPICostUSD(inputTokens, cachedInputTokens, outputTokens, "gpt56Sol");
  return {
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens: points.reduce((total, point) => total + point.tokens, 0),
    calls,
    cacheHitRate: inputTokens === 0 ? 0 : cachedInputTokens / inputTokens,
    costUSD,
  };
}

function quotaConsumptionEstimate(
  breakdown: ReturnType<typeof combineTokenBreakdown>,
  resolution: QuotaDropResolution,
  selectedCostUSD: number,
  comparisonCostUSD: number,
  comparisonBreakdown: ReturnType<typeof combineTokenBreakdown>,
  selectedPoints: RecentUsagePoint[],
  bucketSeconds: number,
): QuotaConsumptionEstimate {
  const drop = Math.max(resolution.percent ?? 0, 0);
  const hasTokenUsage = comparisonBreakdown.totalTokens > 0
    || comparisonBreakdown.inputTokens > 0
    || comparisonBreakdown.outputTokens > 0;
  let confidence: QuotaConsumptionConfidence = "measured";
  let impliedWindowBudgetUSD: number | null = null;
  if (!hasTokenUsage) {
    confidence = "noTokenUsage";
  } else if (drop <= 0.0001) {
    confidence = "insufficientQuotaMovement";
  } else {
    impliedWindowBudgetUSD = comparisonCostUSD / (drop / 100);
  }
  return {
    selectedCostUSD,
    impliedWindowBudgetUSD,
    quotaDropPercent: drop,
    inputTokens: breakdown.inputTokens,
    cachedInputTokens: breakdown.cachedInputTokens,
    outputTokens: breakdown.outputTokens,
    calls: breakdown.calls,
    cacheHitRate: breakdown.cacheHitRate,
    quotaDropAvailable: resolution.percent !== null,
    comparisonBreakdown,
    comparisonStartUnix: resolution.comparisonStartOffset === null
      ? null
      : selectedPoints[resolution.comparisonStartOffset]?.startUnix ?? null,
    comparisonEndUnix: resolution.comparisonStartOffset === null || selectedPoints.length === 0
      ? null
      : selectedPoints[selectedPoints.length - 1].startUnix + bucketSeconds,
    confidence,
  };
}

export function quotaSelectionAttribution(
  selection: QuotaConsumptionSelection,
  context: SharedAccountAttributionResult | null,
): QuotaSelectionAttributionResult | null {
  if (!context
    || !selection.sevenDay.quotaDropAvailable
    || context.priceBasis === null
    || context.radarPlanTotalUSD === null
    || !Number.isFinite(context.radarPlanTotalUSD)
    || context.radarPlanTotalUSD <= 0) {
    return null;
  }

  const localComparableCostUSD = modelAwareAPICostUSD(
    selection.sevenDayModelBreakdowns,
    {
      inputTokens: selection.sevenDay.comparisonBreakdown.inputTokens,
      cachedInputTokens: selection.sevenDay.comparisonBreakdown.cachedInputTokens,
      outputTokens: selection.sevenDay.comparisonBreakdown.outputTokens,
      calls: selection.sevenDay.comparisonBreakdown.calls,
    },
    selection.priceModel,
    context.priceBasis,
  ).costUSD;
  const accountDropPercent = selection.sevenDay.quotaDropPercent;
  const localSharePercent = localComparableCostUSD / context.radarPlanTotalUSD * 100;
  const nonLocalDifferencePercent = accountDropPercent - localSharePercent;
  const quotaCoveredBoundary = context.quotaUpdatedAtUnix === null
    ? null
    : Math.floor(context.quotaUpdatedAtUnix / (5 * 60)) * (5 * 60);
  const allowsAttributionConclusion = (
    context.status === "positiveResidual"
      || context.status === "negativeResidual"
      || context.status === "indistinguishable"
  )
    && !context.quotaDataStale
    && !context.radarDataStale
    && !context.usagePendingQuotaRefresh
    && !context.historyChangedLowConfidence
    && selection.sevenDay.comparisonStartUnix === selection.startUnix
    && (context.cycleStartUnix === null || selection.startUnix >= context.cycleStartUnix)
    && (context.cycleEndUnix === null || selection.endUnix <= context.cycleEndUnix)
    && (context.segmentStartUnix === null || selection.startUnix >= context.segmentStartUnix)
    && (quotaCoveredBoundary === null || selection.endUnix <= quotaCoveredBoundary);
  const state: QuotaSelectionAttributionState = !allowsAttributionConclusion
    ? "provisional"
    : Math.abs(nonLocalDifferencePercent) <= 2
      ? "withinTolerance"
      : nonLocalDifferencePercent > 0
        ? "suspectedNonLocalUsage"
        : "localEstimateExceedsAccountDrop";

  return {
    state,
    accountDropPercent,
    localSharePercent,
    nonLocalDifferencePercent,
    localComparableCostUSD,
    radarSevenDayTotalUSD: context.radarPlanTotalUSD,
    allowsAttributionConclusion,
  };
}

interface QuotaDropResolution {
  percent: number | null;
  comparisonStartOffset: number | null;
}

function quotaDropResolution(values: Array<number | null>): QuotaDropResolution {
  const availableSamples = values.flatMap((value, index) => {
    if (value === null || !Number.isFinite(value)) {
      return [];
    }
    return [{ value: quotaPercentValue(value), index }];
  });
  const sanitizedSamples = availableSamples.filter((sample, index) => {
    const previous = index > 0 ? availableSamples[index - 1].value : null;
    const next = index + 1 < availableSamples.length ? availableSamples[index + 1].value : null;
    return !isZeroRemainingSpike(sample.value, previous, next)
      && !isFullRemainingSpike(sample.value, previous, next);
  });
  if (sanitizedSamples.length < 2) {
    return { percent: null, comparisonStartOffset: values.length > 0 ? 0 : null };
  }
  let currentCycleStart = 0;
  for (let index = 1; index < sanitizedSamples.length; index += 1) {
    if (sanitizedSamples[index].value > sanitizedSamples[index - 1].value + 5) {
      currentCycleStart = index;
    }
  }
  const currentCycleValues = sanitizedSamples.slice(currentCycleStart);
  if (currentCycleValues.length < 2) {
    return { percent: null, comparisonStartOffset: currentCycleValues[0]?.index ?? null };
  }
  return {
    percent: currentCycleValues.slice(1).reduce((total, sample, index) => {
      const previous = currentCycleValues[index].value;
      return total + Math.max(previous - sample.value, 0);
    }, 0),
    comparisonStartOffset: currentCycleValues[0].index,
  };
}

function isZeroRemainingSpike(value: number, previous: number | null, next: number | null): boolean {
  return value <= 1 && previous !== null && previous >= 95 && (next === null || next >= 95);
}

function isFullRemainingSpike(value: number, previous: number | null, next: number | null): boolean {
  return value >= 99
    && previous !== null
    && next !== null
    && previous <= 95
    && next <= previous + 1;
}

function quotaPercentValue(value: number): number {
  return value <= 1 ? value * 100 : value;
}

export function officialAPICostUSD(
  inputTokens: number,
  cachedInputTokens: number,
  outputTokens: number,
  priceModel: OfficialAPIPriceModel,
): number {
  return calculateOfficialAPICostUSD(
    inputTokens,
    cachedInputTokens,
    outputTokens,
    priceModel,
    "current",
  );
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

function markerX(index: number, pointCount: number, chartWidth: number): number {
  return (index / Math.max(pointCount - 1, 1)) * chartWidth;
}

function localDayKey(unix: number): string {
  const date = new Date(unix * 1_000);
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

function formatLocalMonthDay(unix: number): string {
  const date = new Date(unix * 1_000);
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

function formatLocalMonthDayHour(unix: number): string {
  const date = new Date(unix * 1_000);
  return `${date.getMonth() + 1}月${date.getDate()}日 ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
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
