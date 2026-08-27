import type { RecentUsagePoint } from "../../types/dashboard";
import {
  modelAwareAPICostUSD,
  type ModelTokenCostRow,
  type OfficialAPIPriceModel,
} from "../../settings/quotaPriceModel.ts";
import type { SharedAccountAttributionResult } from "../sharedAccountAttribution/model.ts";
import {
  firstCompleteQuotaBucketStart,
  lastCompleteQuotaBucketEnd,
} from "../quotaPeriodBoundary.ts";
import {
  isRenderableRecentChartCost,
  recentChartCostScale,
  recentChartFixedScaleMap,
  recentChartScaleMap,
  recentChartTokenScale,
  recentChartY,
  type RecentChartScaleMap,
  type RecentChartScaleSpec,
} from "./scale.ts";

export {
  RECENT_CHART_TOKEN_PEAK_HEIGHT_RATIO,
  recentChartCostScale,
  recentChartFixedScaleMap,
  recentChartHeightFraction,
  recentChartScaleMap,
  recentChartTokenScale,
  recentChartY,
} from "./scale.ts";

export type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel.ts";

export type RecentChartRange = "24h" | "7d" | "30d";

export interface RecentChartGeometry {
  canvasHeight: number;
  plotTop: number;
  plotHeight: number;
  timeMarkerGap: number;
}

/**
 * All selectable ranges use the same 278px canvas. The plot and marker
 * spacing are scaled with that canvas so pointer hit testing and visual guide
 * lines stay aligned with the rendered paths.
 */
const RECENT_CHART_GEOMETRY: RecentChartGeometry = {
  canvasHeight: 278,
  plotTop: 27,
  plotHeight: 215,
  timeMarkerGap: 36,
};

export function recentChartGeometry(_range: RecentChartRange): RecentChartGeometry {
  return {
    ...RECENT_CHART_GEOMETRY,
  };
}

export interface RecentChartScrollLayout {
  isHorizontal: boolean;
  viewportWidth: number;
  contentWidth: number;
  latestScrollLeft: number;
  windowCount: number;
  className: string;
}

export type RecentChartScrollDirection = "backward" | "forward";

export interface RecentChartScrollPresentation {
  contentOffset: number;
  maxOffset: number;
  viewportWidth: number;
  currentWindowIndex: number;
  windowCount: number;
  isAtOldest: boolean;
  isAtLatest: boolean;
}

export interface RecentChartScrollbarThumb {
  left: number;
  width: number;
  maxScrollLeft: number;
}

export interface RecentUsageChartSeries {
  recentUsage24h: RecentUsagePoint[];
  recentUsage7d: RecentUsagePoint[];
  recentUsage30d: RecentUsagePoint[];
}

export const RECENT_CHART_24H_VIEWPORT_SECONDS = 24 * 60 * 60;

const RECENT_CHART_WINDOW_SECONDS: Record<RecentChartRange, number> = {
  "24h": 24 * 60 * 60,
  "7d": 7 * 24 * 60 * 60,
  "30d": 30 * 24 * 60 * 60,
};

export interface SeriesVisibility {
  tokens: boolean;
  calls: boolean;
  cacheHitRate: boolean;
  cost: boolean;
  fiveHourQuota: boolean;
  sevenDayQuota: boolean;
}

export interface Point {
  x: number;
  y: number;
}

export interface RecentChartScaleWindow {
  startIndex: number;
  endIndex: number;
}

export interface RecentChartPlotOptions {
  bucketCostsUSD?: number[];
  fixedScaleMap?: RecentChartScaleMap;
  renderWindow?: RecentChartScaleWindow | null;
  scaleWindow?: RecentChartScaleWindow | null;
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

export interface RecentChartWindowSummary {
  startIndex: number;
  endIndex: number;
  tokenTotal: number;
  callTotal: number;
  cacheHitRate: number;
  latestFiveHourRemaining: number | null;
  latestSevenDayRemaining: number | null;
  hasCacheCalls: boolean;
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

export interface QuotaConsumptionBoundary {
  resetAtUnix: number | null;
  periodSeconds: number;
}

export interface QuotaConsumptionBoundaryBreakdown {
  leading: TokenBreakdown;
  trailing: TokenBreakdown;
  leadingStartUnix: number | null;
  trailingStartUnix: number | null;
  excludedStartUnix: number[];
}

interface TokenBreakdown {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls: number;
  cacheHitRate: number;
}

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
  comparisonBreakdown: TokenBreakdown;
  boundaryBreakdown: QuotaConsumptionBoundaryBreakdown;
  comparisonStartUnix: number | null;
  comparisonEndUnix: number | null;
  confidence: QuotaConsumptionConfidence;
  excludedModels: string[];
  excludedCalls: number;
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
  excludedModels: string[];
  excludedCalls: number;
  fiveHour: QuotaConsumptionEstimate;
  sevenDay: QuotaConsumptionEstimate;
  sevenDayToFiveHourBudgetRatio: number | null;
  hasDivergentBudgetRatio: boolean;
}

export type QuotaSelectionAttributionState =
  | "withinTolerance"
  | "suspectedNonLocalUsage"
  | "localEstimateExceedsAccountDrop"
  | "provisional"
  | "missingQuotaHistory"
  | "missingRadarTierBaseline"
  | "missingCompatiblePriceRevision";

export interface QuotaSelectionAttributionResult {
  state: QuotaSelectionAttributionState;
  accountDropPercent: number | null;
  localSharePercent: number | null;
  nonLocalDifferencePercent: number | null;
  localComparableCostUSD: number | null;
  localCurrentAPIEquivalentUSD: number;
  excludedModels: string[];
  excludedCalls: number;
  radarSevenDayTotalUSD: number | null;
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
  cost: true,
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
  const intervalCount = Math.max(0, pointCount - 1);
  const defaultBucketSeconds = range === "24h" ? 5 * 60 : range === "7d" ? 60 * 60 : 6 * 60 * 60;
  const safeBucketSeconds = Number.isFinite(bucketSeconds) && bucketSeconds > 0 ? bucketSeconds : defaultBucketSeconds;
  const viewportDurationSeconds = RECENT_CHART_WINDOW_SECONDS[range];
  const contentDurationSeconds = Math.max(intervalCount * safeBucketSeconds, viewportDurationSeconds);
  const rawContentWidth = intervalCount > 0
    ? Math.round((contentDurationSeconds / viewportDurationSeconds) * safeViewportWidth)
    : safeViewportWidth;
  const contentWidth = Math.max(safeViewportWidth, rawContentWidth);
  const windowCount = Math.max(1, Math.ceil(contentDurationSeconds / viewportDurationSeconds));

  return {
    isHorizontal: contentWidth > safeViewportWidth,
    viewportWidth: safeViewportWidth,
    contentWidth,
    latestScrollLeft: Math.max(0, contentWidth - safeViewportWidth),
    windowCount,
    className: contentWidth > safeViewportWidth
      ? "recent-chart-scroll recent-chart-scroll--horizontal"
      : "recent-chart-scroll",
  };
}

export function recentChartScrollPresentation(
  layout: Pick<RecentChartScrollLayout, "contentWidth" | "viewportWidth" | "windowCount">,
  contentOffset: number,
  epsilon = 0.5,
): RecentChartScrollPresentation {
  const safeViewportWidth = Math.max(0, Number.isFinite(layout.viewportWidth) ? layout.viewportWidth : 0);
  const safeContentWidth = Math.max(0, Number.isFinite(layout.contentWidth) ? layout.contentWidth : 0);
  const maxOffset = Math.max(safeContentWidth - safeViewportWidth, 0);
  const safeOffset = Number.isFinite(contentOffset) ? clamp(contentOffset, 0, maxOffset) : 0;
  const safeWindowCount = Math.max(1, Math.floor(Number.isFinite(layout.windowCount) ? layout.windowCount : 1));
  const safeEpsilon = Math.max(0, Number.isFinite(epsilon) ? epsilon : 0);
  const upperWindowIndex = safeWindowCount - 1;
  const currentWindowIndex = safeViewportWidth > 0
    ? clamp(Math.floor((safeOffset + safeEpsilon) / safeViewportWidth), 0, upperWindowIndex)
    : 0;
  return {
    contentOffset: safeOffset,
    maxOffset,
    viewportWidth: safeViewportWidth,
    currentWindowIndex,
    windowCount: safeWindowCount,
    isAtOldest: safeOffset <= safeEpsilon,
    isAtLatest: maxOffset - safeOffset <= safeEpsilon,
  };
}

export function recentChartScrollbarThumb(
  layout: Pick<RecentChartScrollLayout, "contentWidth" | "viewportWidth">,
  scrollLeft: number,
  trackWidth = layout.viewportWidth,
  minimumThumbWidth = 36,
): RecentChartScrollbarThumb {
  const safeTrackWidth = Math.max(0, Number.isFinite(trackWidth) ? trackWidth : 0);
  const safeViewportWidth = Math.max(0, Number.isFinite(layout.viewportWidth) ? layout.viewportWidth : 0);
  const safeContentWidth = Math.max(safeViewportWidth, Number.isFinite(layout.contentWidth) ? layout.contentWidth : 0);
  const maxScrollLeft = Math.max(safeContentWidth - safeViewportWidth, 0);
  const proportionalWidth = safeContentWidth > 0
    ? safeTrackWidth * safeViewportWidth / safeContentWidth
    : safeTrackWidth;
  const width = Math.min(
    safeTrackWidth,
    Math.max(Math.min(Math.max(minimumThumbWidth, 0), safeTrackWidth), proportionalWidth),
  );
  const availableTravel = Math.max(safeTrackWidth - width, 0);
  const clampedScrollLeft = Math.min(Math.max(Number.isFinite(scrollLeft) ? scrollLeft : 0, 0), maxScrollLeft);
  const left = maxScrollLeft > 0
    ? availableTravel * clampedScrollLeft / maxScrollLeft
    : 0;
  return { left, width, maxScrollLeft };
}

export function recentChartScrollLeftForThumb(
  thumbLeft: number,
  thumb: Pick<RecentChartScrollbarThumb, "width" | "maxScrollLeft">,
  trackWidth: number,
): number {
  const safeTrackWidth = Math.max(0, Number.isFinite(trackWidth) ? trackWidth : 0);
  const availableTravel = Math.max(safeTrackWidth - thumb.width, 0);
  if (availableTravel <= 0 || thumb.maxScrollLeft <= 0) return 0;
  const clampedLeft = Math.min(Math.max(Number.isFinite(thumbLeft) ? thumbLeft : 0, 0), availableTravel);
  return thumb.maxScrollLeft * clampedLeft / availableTravel;
}

export function recentChartScrollTarget(
  layout: Pick<RecentChartScrollLayout, "contentWidth" | "viewportWidth" | "windowCount">,
  contentOffset: number,
  direction: RecentChartScrollDirection,
): number {
  const presentation = recentChartScrollPresentation(layout, contentOffset);
  if (presentation.windowCount <= 1 || presentation.viewportWidth <= 0) {
    return presentation.contentOffset;
  }
  const delta = direction === "forward" ? 1 : -1;
  const targetWindowIndex = clamp(
    presentation.currentWindowIndex + delta,
    0,
    presentation.windowCount - 1,
  );
  return targetWindowIndex >= presentation.windowCount - 1
    ? presentation.maxOffset
    : Math.min(targetWindowIndex * presentation.viewportWidth, presentation.maxOffset);
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

export function plotChartPoints(
  data: PreparedRecentChartData,
  width: number,
  plotHeight: number,
  priceModel: OfficialAPIPriceModel = "gpt56Sol",
  options: RecentChartPlotOptions = {},
) {
  const step = width / Math.max(data.points.length - 1, 1);
  const bucketCostsUSD = options.bucketCostsUSD?.length === data.points.length
    ? options.bucketCostsUSD
    : recentChartBucketCosts(data.points, priceModel);
  const scaleWindow = clampedScaleWindow(options.scaleWindow, data.points.length);
  const scalePoints = scaleWindow === null
    ? data.points
    : data.points.slice(scaleWindow.startIndex, scaleWindow.endIndex + 1);
  const scaleCosts = scaleWindow === null
    ? bucketCostsUSD
    : bucketCostsUSD.slice(scaleWindow.startIndex, scaleWindow.endIndex + 1);
  const fixedScaleMap = options.fixedScaleMap
    ?? recentChartFixedScaleMap(data.points.map((point) => point.calls));
  const scaleMap: RecentChartScaleMap = {
    ...fixedScaleMap,
    tokens: recentChartTokenScale(scalePoints.map((point) => point.tokens)),
    cost: recentChartCostScale(scaleCosts),
  };
  const renderWindow = clampedScaleWindow(options.renderWindow, data.points.length);
  const renderStartIndex = renderWindow?.startIndex ?? 0;
  const renderEndIndex = renderWindow?.endIndex ?? Math.max(data.points.length - 1, -1);
  const renderPoints = renderEndIndex >= renderStartIndex
    ? data.points.slice(renderStartIndex, renderEndIndex + 1)
    : [];
  const renderCosts = renderEndIndex >= renderStartIndex
    ? bucketCostsUSD.slice(renderStartIndex, renderEndIndex + 1)
    : [];
  return {
    scaleMap,
    renderStartIndex,
    renderEndIndex,
    tokenPoints: renderPoints.map((point, index) => ({
      x: (renderStartIndex + index) * step,
      y: recentChartY(point.tokens, scaleMap.tokens, plotHeight),
    })),
    callPoints: renderPoints.map((point, index) => ({
      x: (renderStartIndex + index) * step,
      y: recentChartY(point.calls, scaleMap.calls, plotHeight),
    })),
    cachePoints: renderPoints.map((_, index) => {
      const globalIndex = renderStartIndex + index;
      const rate = data.observedCacheHitRates[globalIndex];
      return rate === null || rate === undefined
        ? null
        : { x: globalIndex * step, y: recentChartY(rate, scaleMap.cacheHitRate, plotHeight) };
    }),
    bucketCostsUSD,
    costPoints: scaledCostPoints(
      renderCosts,
      width,
      plotHeight,
      scaleMap.cost,
      renderStartIndex,
      data.points.length,
    ),
    fiveHourQuotaPoints: optionalQuotaPoints(
      renderPoints,
      "fiveHourRemainingPercent",
      width,
      plotHeight,
      scaleMap.quota,
      renderStartIndex,
      data.points.length,
    ),
    sevenDayQuotaPoints: optionalQuotaPoints(
      renderPoints,
      "sevenDayRemainingPercent",
      width,
      plotHeight,
      scaleMap.quota,
      renderStartIndex,
      data.points.length,
    ),
  };
}

export function recentChartBucketCosts(
  points: RecentUsagePoint[],
  priceModel: OfficialAPIPriceModel,
): number[] {
  return points.map((point) => {
    const fallback = {
      inputTokens: finiteNonnegative(point.inputTokens),
      cachedInputTokens: Math.min(finiteNonnegative(point.cachedInputTokens), finiteNonnegative(point.inputTokens)),
      outputTokens: finiteNonnegative(point.outputTokens),
      calls: finiteNonnegative(point.calls),
    };
    const estimate = modelAwareAPICostUSD(
      modelRowsForPoints([point]),
      fallback,
      priceModel,
    );
    return Number.isFinite(estimate.costUSD) ? Math.max(estimate.costUSD, 0) : 0;
  });
}

export function scaledCostPoints(
  costs: number[],
  width: number,
  plotHeight: number,
  scale: RecentChartScaleSpec = recentChartScaleMap({ tokenValues: [1], callValues: [1], costs }).cost,
  startIndex = 0,
  totalPointCount = costs.length,
): Array<Point | null> {
  if (costs.length === 0) {
    return [];
  }
  const safeCosts = costs.map((cost) => Number.isFinite(cost) ? Math.max(cost, 0) : 0);
  const step = width / Math.max(totalPointCount - 1, 1);
  return safeCosts.map((cost, index) => {
    if (!isRenderableRecentChartCost(cost)) {
      return null;
    }
    return {
      x: (startIndex + index) * step,
      y: recentChartY(cost, scale, plotHeight),
    };
  });
}

function clampedScaleWindow(
  scaleWindow: RecentChartScaleWindow | null | undefined,
  pointCount: number,
): RecentChartScaleWindow | null {
  if (scaleWindow === null || scaleWindow === undefined || pointCount <= 0) {
    return null;
  }
  const lastIndex = pointCount - 1;
  const startIndex = clamp(Math.floor(scaleWindow.startIndex), 0, lastIndex);
  const endIndex = clamp(Math.floor(scaleWindow.endIndex), startIndex, lastIndex);
  return { startIndex, endIndex };
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

export function recentChartVisibleWindowIndices(
  data: Pick<PreparedRecentChartData, "range" | "points" | "bucketSeconds">,
  chartWidth: number,
  scrollLeft: number,
  viewportWidth: number,
): { startIndex: number; endIndex: number } | null {
  if (data.points.length === 0) {
    return null;
  }

  const safeChartWidth = Number.isFinite(chartWidth) && chartWidth > 0 ? chartWidth : 980;
  const safeViewportWidth = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 980;
  const maxScrollLeft = Math.max(0, safeChartWidth - safeViewportWidth);
  const safeScrollLeft = Number.isFinite(scrollLeft) ? clamp(scrollLeft, 0, maxScrollLeft) : 0;
  const lastIndex = data.points.length - 1;
  const viewportBucketCount = Math.max(
    1,
    Math.round(RECENT_CHART_WINDOW_SECONDS[data.range] / data.bucketSeconds),
  );
  const startIndex = maxScrollLeft - safeScrollLeft <= 0.5
    ? Math.max(lastIndex - viewportBucketCount + 1, 0)
    : safeScrollLeft <= 0.5
      ? 0
      : hoverIndexForX(safeScrollLeft, safeChartWidth, data.points.length) ?? 0;
  const endIndex = clamp(startIndex + viewportBucketCount - 1, startIndex, lastIndex);
  return { startIndex, endIndex };
}

export function recentChartVisibleWindowSummary(
  data: PreparedRecentChartData,
  chartWidth: number,
  scrollLeft: number,
  viewportWidth: number,
): RecentChartWindowSummary {
  const indices = recentChartVisibleWindowIndices(data, chartWidth, scrollLeft, viewportWidth);
  if (indices === null) {
    return {
      startIndex: 0,
      endIndex: -1,
      tokenTotal: 0,
      callTotal: 0,
      cacheHitRate: 0,
      latestFiveHourRemaining: null,
      latestSevenDayRemaining: null,
      hasCacheCalls: false,
    };
  }

  const points = data.points.slice(indices.startIndex, indices.endIndex + 1);
  return {
    ...indices,
    tokenTotal: points.reduce((total, point) => total + point.tokens, 0),
    callTotal: points.reduce((total, point) => total + point.calls, 0),
    cacheHitRate: weightedCacheHitRate(points),
    latestFiveHourRemaining: latestPresent(points.map((point) => point.fiveHourRemainingPercent)),
    latestSevenDayRemaining: latestPresent(points.map((point) => point.sevenDayRemainingPercent)),
    hasCacheCalls: points.some((point) => point.calls > 0 && point.cacheHitRate !== null),
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

export function tokenAreaPath(points: Point[], _width: number, plotHeight: number): string {
    const first = points[0];
    const last = points[points.length - 1];
    if (!first || !last) {
      return "";
    }
    return [
      smoothPath(points),
      `L ${formatNumber(last.x)} ${formatNumber(plotHeight)}`,
      `L ${formatNumber(first.x)} ${formatNumber(plotHeight)}`,
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

/**
 * Returns the CSS `left` value for a bubble that uses `translateX(-50%)`.
 * The center is clamped from the measured bubble width, so either edge can
 * meet the viewport boundary without relying on a fixed-width guess.
 */
export function recentChartHoverBubbleCenter(
  x: number,
  viewportWidth: number,
  bubbleWidth: number,
  edgePadding = 0,
): number {
  const safeViewportWidth = Number.isFinite(viewportWidth) ? Math.max(viewportWidth, 0) : 0;
  const safeBubbleWidth = Number.isFinite(bubbleWidth) ? Math.max(bubbleWidth, 0) : 0;
  const safeEdgePadding = Number.isFinite(edgePadding) ? Math.max(edgePadding, 0) : 0;
  const halfWidth = safeBubbleWidth / 2;
  const minimumCenter = safeEdgePadding + halfWidth;
  const maximumCenter = safeViewportWidth - safeEdgePadding - halfWidth;
  const desiredCenter = Number.isFinite(x) ? x : safeViewportWidth / 2;

  // If the card is wider than the viewport, keep its right edge inside the
  // viewport; there is no position that can keep both edges visible.
  if (maximumCenter < minimumCenter) {
    return maximumCenter;
  }
  return clamp(desiredCenter, minimumCenter, maximumCenter);
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

export function shouldReopenPreviewOnHoverMove(
  fixedEndIndex: number | null,
  previousHoveredIndex: number | null,
  nextHoveredIndex: number | null,
): boolean {
  return fixedEndIndex === null && nextHoveredIndex !== previousHoveredIndex;
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
  boundaries: {
    fiveHour?: QuotaConsumptionBoundary | null;
    sevenDay?: QuotaConsumptionBoundary | null;
  } = {},
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
  const selectedEstimate = modelAwareAPICostUSD(
    modelRowsForPoints(selectedPoints),
    breakdown,
    priceModel,
  );
  const fiveHourDrop = quotaDropResolution(
    selectedPoints,
    "fiveHourRemainingPercent",
    "fiveHourCycleId",
  );
  const sevenDayDrop = quotaDropResolution(
    selectedPoints,
    "sevenDayRemainingPercent",
    "sevenDayCycleId",
  );
  const fiveHourBoundaryBreakdown = quotaBoundaryBreakdown(
    selectedPoints,
    boundaries.fiveHour,
    data.bucketSeconds,
  );
  const sevenDayBoundaryBreakdown = quotaBoundaryBreakdown(
    selectedPoints,
    boundaries.sevenDay,
    data.bucketSeconds,
  );
  const fiveHourComparisonPoints = comparisonPoints(
    selectedPoints,
    fiveHourDrop,
    fiveHourBoundaryBreakdown,
  );
  const sevenDayComparisonPoints = comparisonPoints(
    selectedPoints,
    sevenDayDrop,
    sevenDayBoundaryBreakdown,
  );
  const fiveHourComparisonBreakdown = combineTokenBreakdown(fiveHourComparisonPoints);
  const sevenDayComparisonBreakdown = combineTokenBreakdown(sevenDayComparisonPoints);
  const fiveHourComparisonEstimate = modelAwareAPICostUSD(
    modelRowsForPoints(fiveHourComparisonPoints),
    fiveHourComparisonBreakdown,
    priceModel,
  );
  const sevenDayModelBreakdowns = modelRowsForPoints(sevenDayComparisonPoints);
  const sevenDayComparisonEstimate = modelAwareAPICostUSD(
    sevenDayModelBreakdowns,
    sevenDayComparisonBreakdown,
    priceModel,
  );
  const fiveHour = quotaConsumptionEstimate(
    breakdown,
    fiveHourDrop,
    selectedEstimate.costUSD,
    fiveHourComparisonEstimate.costUSD,
    fiveHourComparisonBreakdown,
    fiveHourComparisonEstimate,
    fiveHourBoundaryBreakdown,
    fiveHourComparisonPoints,
    data.bucketSeconds,
  );
  const sevenDay = quotaConsumptionEstimate(
    breakdown,
    sevenDayDrop,
    selectedEstimate.costUSD,
    sevenDayComparisonEstimate.costUSD,
    sevenDayComparisonBreakdown,
    sevenDayComparisonEstimate,
    sevenDayBoundaryBreakdown,
    sevenDayComparisonPoints,
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
    selectedCostUSD: selectedEstimate.costUSD,
    totalTokens: breakdown.totalTokens,
    inputTokens: breakdown.inputTokens,
    cachedInputTokens: breakdown.cachedInputTokens,
    outputTokens: breakdown.outputTokens,
    calls: breakdown.calls,
    cacheHitRate: breakdown.cacheHitRate,
    modelBreakdowns: modelRowsForPoints(selectedPoints),
    sevenDayModelBreakdowns,
    excludedModels: selectedEstimate.excludedModels,
    excludedCalls: selectedEstimate.excludedCalls,
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

export function quotaComparisonScopeText(
  selection: QuotaConsumptionSelection,
  visibility: QuotaEstimateWindowVisibility,
): string | null {
  const narrowedWindows = [
    visibility.fiveHour && usesNarrowerComparison(selection.fiveHour, selection) ? "5h" : null,
    visibility.sevenDay && usesNarrowerComparison(selection.sevenDay, selection) ? "7d" : null,
  ].filter((value): value is string => value !== null);
  return narrowedWindows.length === 0
    ? null
    : `${narrowedWindows.join("/")} 反推仅按同周期可比区间`;
}

function usesNarrowerComparison(
  estimate: QuotaConsumptionEstimate,
  selection: QuotaConsumptionSelection,
): boolean {
  return estimate.quotaDropAvailable
    && estimate.comparisonStartUnix !== null
    && estimate.comparisonEndUnix !== null
    && (estimate.comparisonStartUnix > selection.startUnix + 0.5
      || estimate.comparisonEndUnix < selection.endUnix - 0.5);
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
  scale: RecentChartScaleSpec,
  startIndex = 0,
  totalPointCount = points.length,
): Array<Point | null> {
  const step = width / Math.max(totalPointCount - 1, 1);
  return points.map((point, index) => {
    const value = point[key];
    if (value === null) {
      return null;
    }
    return {
      x: (startIndex + index) * step,
      y: recentChartY(value, scale, plotHeight),
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

function modelRowsForPoints(points: RecentUsagePoint[]): ModelTokenCostRow[] {
  return points.flatMap((point) => (point.modelBreakdowns ?? []).map((row) => ({
    ...row,
    eventStartUnix: row.eventStartUnix ?? point.startUnix,
  })));
}

function combineTokenBreakdown(points: RecentUsagePoint[]) {
  const inputTokens = points.reduce((total, point) => total + point.inputTokens, 0);
  const cachedInputTokens = points.reduce((total, point) => total + point.cachedInputTokens, 0);
  // Native exact history exposes output tokens directly. Do not reinterpret
  // total-minus-input as output: total may include non-billable or separately
  // classified token dimensions.
  const outputTokens = points.reduce((total, point) => total + finiteNonnegative(point.outputTokens), 0);
  const calls = points.reduce((total, point) => total + point.calls, 0);
  return {
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens: points.reduce((total, point) => total + point.tokens, 0),
    calls,
    cacheHitRate: inputTokens === 0 ? 0 : cachedInputTokens / inputTokens,
  };
}

function quotaBoundaryBreakdown(
  points: RecentUsagePoint[],
  boundary: QuotaConsumptionBoundary | null | undefined,
  bucketSeconds: number,
): QuotaConsumptionBoundaryBreakdown {
  const empty = combineTokenBreakdown([]);
  if (!boundary
    || typeof boundary.resetAtUnix !== "number"
    || !Number.isFinite(boundary.resetAtUnix)
    || !Number.isFinite(boundary.periodSeconds)
    || boundary.periodSeconds <= 0
    || !Number.isFinite(bucketSeconds)
    || bucketSeconds <= 0) {
    return {
      leading: empty,
      trailing: empty,
      leadingStartUnix: null,
      trailingStartUnix: null,
      excludedStartUnix: [],
    };
  }

  const periodStartUnix = boundary.resetAtUnix - boundary.periodSeconds;
  const rawStartBucket = bucketStart(periodStartUnix, bucketSeconds);
  const rawEndBucket = bucketStart(boundary.resetAtUnix, bucketSeconds);
  const safeStartUnix = firstCompleteQuotaBucketStart(periodStartUnix, bucketSeconds);
  const safeEndUnix = lastCompleteQuotaBucketEnd(boundary.resetAtUnix, bucketSeconds);
  const rawEndExclusive = isBucketAligned(boundary.resetAtUnix, bucketSeconds)
    ? boundary.resetAtUnix
    : rawEndBucket + bucketSeconds;
  const leadingStarts = !isBucketAligned(periodStartUnix, bucketSeconds)
    ? points
      .filter((point) => point.startUnix >= rawStartBucket && point.startUnix < safeStartUnix)
      .map((point) => point.startUnix)
    : [];
  const trailingStarts = !isBucketAligned(boundary.resetAtUnix, bucketSeconds)
    ? points
      .filter((point) => point.startUnix >= safeEndUnix && point.startUnix < rawEndExclusive)
      .map((point) => point.startUnix)
    : [];
  const leadingSet = new Set(leadingStarts);
  const trailingSet = new Set(trailingStarts.filter((startUnix) => !leadingSet.has(startUnix)));
  const pointAt = (starts: Set<number>): TokenBreakdown => (
    starts.size === 0
      ? empty
      : combineTokenBreakdown(points.filter((point) => starts.has(point.startUnix)))
  );
  const excludedStartUnix = [...new Set([...leadingSet, ...trailingSet])].sort((left, right) => left - right);
  return {
    leading: pointAt(leadingSet),
    trailing: pointAt(trailingSet),
    leadingStartUnix: leadingStarts[0] ?? null,
    trailingStartUnix: trailingStarts.find((startUnix) => trailingSet.has(startUnix)) ?? null,
    excludedStartUnix,
  };
}

function comparisonPoints(
  points: RecentUsagePoint[],
  resolution: QuotaDropResolution,
  boundary: QuotaConsumptionBoundaryBreakdown,
): RecentUsagePoint[] {
  if (resolution.comparisonStartOffset === null) return [];
  const edgeStarts = new Set(
    boundary.excludedStartUnix,
  );
  return points
    .slice(resolution.comparisonStartOffset)
    .filter((point) => !edgeStarts.has(point.startUnix));
}

function bucketStart(unix: number, bucketSeconds: number): number {
  return Math.floor(unix / bucketSeconds) * bucketSeconds;
}

function isBucketAligned(unix: number, bucketSeconds: number): boolean {
  return Math.abs(unix - bucketStart(unix, bucketSeconds)) <= 1e-6;
}

function quotaConsumptionEstimate(
  breakdown: ReturnType<typeof combineTokenBreakdown>,
  resolution: QuotaDropResolution,
  selectedCostUSD: number,
  comparisonCostUSD: number,
  comparisonBreakdown: ReturnType<typeof combineTokenBreakdown>,
  comparisonEstimate: ReturnType<typeof modelAwareAPICostUSD>,
  boundaryBreakdown: QuotaConsumptionBoundaryBreakdown,
  comparisonPoints: RecentUsagePoint[],
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
    boundaryBreakdown,
    comparisonStartUnix: comparisonPoints.length === 0
      ? null
      : comparisonPoints[0]?.startUnix ?? null,
    comparisonEndUnix: comparisonPoints.length === 0
      ? null
      : comparisonPoints[comparisonPoints.length - 1].startUnix + bucketSeconds,
    confidence,
    excludedModels: comparisonEstimate.excludedModels,
    excludedCalls: comparisonEstimate.excludedCalls,
  };
}

export function quotaSelectionAttribution(
  selection: QuotaConsumptionSelection,
  context: SharedAccountAttributionResult | null,
): QuotaSelectionAttributionResult | null {
  if (!context) {
    return null;
  }

  const comparisonRows = selection.sevenDayModelBreakdowns;
  const comparisonBreakdown = {
    inputTokens: selection.sevenDay.comparisonBreakdown.inputTokens,
    cachedInputTokens: selection.sevenDay.comparisonBreakdown.cachedInputTokens,
    outputTokens: selection.sevenDay.comparisonBreakdown.outputTokens,
    calls: selection.sevenDay.comparisonBreakdown.calls,
  };
  const localCurrentAPIEquivalent = modelAwareAPICostUSD(
    comparisonRows,
    comparisonBreakdown,
    selection.priceModel,
    "current",
  );
  const localComparableEstimate = context.priceBasis === null
    ? null
    : modelAwareAPICostUSD(
        selection.sevenDayModelBreakdowns,
        comparisonBreakdown,
        selection.priceModel,
        context.priceBasis,
      );
  const localComparableCostUSD = localComparableEstimate?.costUSD ?? null;
  const radarSevenDayTotalUSD = context.radarPlanTotalUSD !== null
    && Number.isFinite(context.radarPlanTotalUSD)
    && context.radarPlanTotalUSD > 0
    ? context.radarPlanTotalUSD
    : null;
  const accountDropPercent = selection.sevenDay.quotaDropAvailable
    ? selection.sevenDay.quotaDropPercent
    : null;
  const localSharePercent = localComparableCostUSD !== null && radarSevenDayTotalUSD !== null
    ? localComparableCostUSD / radarSevenDayTotalUSD * 100
    : null;
  const nonLocalDifferencePercent = accountDropPercent !== null && localSharePercent !== null
    ? accountDropPercent - localSharePercent
    : null;
  const quotaCoveredBoundary = context.quotaUpdatedAtUnix === null
    ? null
    : Math.floor(context.quotaUpdatedAtUnix / (5 * 60)) * (5 * 60);
  const allowsAttributionConclusion = accountDropPercent !== null
    && localSharePercent !== null
    && (
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
  const state: QuotaSelectionAttributionState = context.priceBasis === null
    ? "missingCompatiblePriceRevision"
    : radarSevenDayTotalUSD === null
      ? "missingRadarTierBaseline"
      : accountDropPercent === null
        ? "missingQuotaHistory"
        : !allowsAttributionConclusion
          ? "provisional"
          : Math.abs(nonLocalDifferencePercent ?? 0) <= 2
            ? "withinTolerance"
            : (nonLocalDifferencePercent ?? 0) > 0
              ? "suspectedNonLocalUsage"
              : "localEstimateExceedsAccountDrop";

  return {
    state,
    accountDropPercent,
    localSharePercent,
    nonLocalDifferencePercent,
    localComparableCostUSD,
    localCurrentAPIEquivalentUSD: localCurrentAPIEquivalent.costUSD,
    excludedModels: localCurrentAPIEquivalent.excludedModels,
    excludedCalls: localCurrentAPIEquivalent.excludedCalls,
    radarSevenDayTotalUSD,
    allowsAttributionConclusion,
  };
}

interface QuotaDropResolution {
  percent: number | null;
  comparisonStartOffset: number | null;
}

function quotaDropResolution(
  points: RecentUsagePoint[],
  valueKey: "fiveHourRemainingPercent" | "sevenDayRemainingPercent",
  cycleKey: "fiveHourCycleId" | "sevenDayCycleId",
): QuotaDropResolution {
  const availableSamples = points.flatMap((point, index) => {
    const value = point[valueKey];
    if (value === null || !Number.isFinite(value)) {
      return [];
    }
    return [{
      value: quotaPercentValue(value),
      cycleId: normalizedCycleId(point[cycleKey]),
      index,
    }];
  });
  if (availableSamples.length < 2) {
    return {
      percent: null,
      comparisonStartOffset: availableSamples[0]?.index ?? (points.length > 0 ? 0 : null),
    };
  }

  const latestCycleId = availableSamples.at(-1)?.cycleId ?? null;
  if (latestCycleId === null) {
    // Legacy/ambiguous history remains drawable, but is never inverted into a
    // quota budget without an authoritative backend cycle assignment.
    return { percent: null, comparisonStartOffset: null };
  }
  let currentCycleStart = availableSamples.length - 1;
  while (currentCycleStart > 0
    && availableSamples[currentCycleStart - 1].cycleId === latestCycleId) {
    currentCycleStart -= 1;
  }
  const currentCycleSamples = availableSamples.slice(currentCycleStart);
  const sanitizedSamples = currentCycleSamples.filter((sample, index) => {
    const previous = index > 0 ? currentCycleSamples[index - 1].value : null;
    const next = index + 1 < currentCycleSamples.length ? currentCycleSamples[index + 1].value : null;
    return !isZeroRemainingSpike(sample.value, previous, next)
      && !isFullRemainingSpike(sample.value, previous, next);
  });
  if (sanitizedSamples.length < 2) {
    return { percent: null, comparisonStartOffset: sanitizedSamples[0]?.index ?? null };
  }
  return {
    percent: sanitizedSamples.slice(1).reduce((total, sample, index) => {
      const previous = sanitizedSamples[index].value;
      return total + Math.max(previous - sample.value, 0);
    }, 0),
    comparisonStartOffset: sanitizedSamples[0].index,
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

function normalizedCycleId(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
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
