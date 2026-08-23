export type RecentChartScaleTransform = "linear" | "log1p";

export interface RecentChartScaleSpec {
  transform: RecentChartScaleTransform;
  minimum: number;
  maximum: number;
  outputMinimum: number;
  outputMaximum: number;
  midpoint?: number;
  outputMidpoint?: number;
}

export interface RecentChartScaleMap {
  tokens: RecentChartScaleSpec;
  calls: RecentChartScaleSpec;
  cacheHitRate: RecentChartScaleSpec;
  cost: RecentChartScaleSpec;
  quota: RecentChartScaleSpec;
}

/** Token alone keeps a 35% top gutter. Percentage series retain their true 0–100% axis. */
export const RECENT_CHART_TOKEN_PEAK_HEIGHT_RATIO = 0.65;
export const RECENT_CHART_COST_LOW_HEIGHT_RATIO = 0.45;
export const RECENT_CHART_COST_AVERAGE_HEIGHT_RATIO = 0.7;
export const RECENT_CHART_COST_HIGH_HEIGHT_RATIO = 0.95;
export const RECENT_CHART_COST_POINT_MINIMUM_RADIUS = 1.6;
export const RECENT_CHART_COST_POINT_MAXIMUM_RADIUS = 4.2;

export function recentChartScaleMap({
  tokenValues,
  callValues,
  costs,
}: {
  tokenValues: number[];
  callValues: number[];
  costs: number[];
}): RecentChartScaleMap {
  const renderableCosts = costs.filter(isRenderableRecentChartCost);
  const costMinimum = Math.min(...renderableCosts, Number.POSITIVE_INFINITY);
  const costMaximum = Math.max(...renderableCosts, 0);
  const costAverage = renderableCosts.length > 0
    ? renderableCosts.reduce((total, cost) => total + cost, 0) / renderableCosts.length
    : 0;

  return {
    tokens: recentChartTokenScale(tokenValues),
    calls: linearScale(maximumOf(callValues), 1),
    cacheHitRate: linearScale(1, 1),
    cost: {
      transform: "log1p",
      minimum: Number.isFinite(costMinimum) ? costMinimum : 0,
      maximum: costMaximum,
      outputMinimum: RECENT_CHART_COST_LOW_HEIGHT_RATIO,
      outputMaximum: RECENT_CHART_COST_HIGH_HEIGHT_RATIO,
      ...(costAverage > 0 ? {
        midpoint: costAverage,
        outputMidpoint: RECENT_CHART_COST_AVERAGE_HEIGHT_RATIO,
      } : {}),
    },
    quota: linearScale(1, 1),
  };
}

export function recentChartTokenScale(tokenValues: number[]): RecentChartScaleSpec {
  return linearScale(maximumOf(tokenValues), RECENT_CHART_TOKEN_PEAK_HEIGHT_RATIO);
}

/** Returns the visual height fraction measured upward from the plot baseline. */
export function recentChartHeightFraction(value: number, scale: RecentChartScaleSpec): number {
  const minimum = finiteNonnegative(scale.minimum);
  const maximum = Math.max(finiteNonnegative(scale.maximum), minimum);
  const outputMinimum = clamp(finiteNonnegative(scale.outputMinimum), 0, 1);
  const outputMaximum = clamp(finiteNonnegative(scale.outputMaximum), outputMinimum, 1);
  const safeValue = clamp(finiteNonnegative(value), minimum, maximum);
  if (maximum - minimum <= Number.EPSILON) {
    if (maximum <= Number.EPSILON || value <= 0) {
      return 0;
    }
    return clamp(scale.outputMidpoint ?? outputMaximum, outputMinimum, outputMaximum);
  }

  const transformedValue = transform(safeValue, scale.transform);
  const transformedMinimum = transform(minimum, scale.transform);
  const transformedMaximum = transform(maximum, scale.transform);
  if (transformedMaximum - transformedMinimum <= Number.EPSILON) {
    return outputMinimum;
  }

  const midpoint = scale.midpoint === undefined
    ? null
    : clamp(finiteNonnegative(scale.midpoint), minimum, maximum);
  const outputMidpoint = scale.outputMidpoint === undefined
    ? null
    : clamp(finiteNonnegative(scale.outputMidpoint), outputMinimum, outputMaximum);
  if (midpoint !== null && outputMidpoint !== null) {
    const transformedMidpoint = transform(midpoint, scale.transform);
    if (transformedValue <= transformedMidpoint) {
      return interpolate(
        transformedValue,
        transformedMinimum,
        transformedMidpoint,
        outputMinimum,
        outputMidpoint,
      );
    }
    return interpolate(
      transformedValue,
      transformedMidpoint,
      transformedMaximum,
      outputMidpoint,
      outputMaximum,
    );
  }

  return interpolate(
    transformedValue,
    transformedMinimum,
    transformedMaximum,
    outputMinimum,
    outputMaximum,
  );
}

export function recentChartY(
  value: number,
  scale: RecentChartScaleSpec,
  plotHeight: number,
): number {
  const safePlotHeight = finiteNonnegative(plotHeight);
  return (1 - recentChartHeightFraction(value, scale)) * safePlotHeight;
}

export function recentChartCostPointRadius(
  cost: number,
  scale: RecentChartScaleSpec,
): number {
  if (!isRenderableRecentChartCost(cost)) return 0;
  const visualSpan = RECENT_CHART_COST_HIGH_HEIGHT_RATIO - RECENT_CHART_COST_LOW_HEIGHT_RATIO;
  if (visualSpan <= Number.EPSILON) return RECENT_CHART_COST_POINT_MINIMUM_RADIUS;
  const normalized = clamp(
    (recentChartHeightFraction(cost, scale) - RECENT_CHART_COST_LOW_HEIGHT_RATIO) / visualSpan,
    0,
    1,
  );
  return RECENT_CHART_COST_POINT_MINIMUM_RADIUS
    + (RECENT_CHART_COST_POINT_MAXIMUM_RADIUS - RECENT_CHART_COST_POINT_MINIMUM_RADIUS) * normalized;
}

export function isRenderableRecentChartCost(cost: number): boolean {
  return Number.isFinite(cost) && cost > 0;
}

function linearScale(maximum: number, outputMaximum: number): RecentChartScaleSpec {
  return {
    transform: "linear",
    minimum: 0,
    maximum: Math.max(finiteNonnegative(maximum), 1),
    outputMinimum: 0,
    outputMaximum,
  };
}

function maximumOf(values: number[]): number {
  return values.reduce((maximum, value) => Math.max(maximum, finiteNonnegative(value)), 0);
}

function transform(value: number, kind: RecentChartScaleTransform): number {
  return kind === "log1p" ? Math.log1p(value) : value;
}

function interpolate(
  value: number,
  inputMinimum: number,
  inputMaximum: number,
  outputMinimum: number,
  outputMaximum: number,
): number {
  const inputSpan = inputMaximum - inputMinimum;
  if (inputSpan <= Number.EPSILON) {
    return clamp(outputMaximum, outputMinimum, outputMaximum);
  }
  return clamp(
    outputMinimum + (outputMaximum - outputMinimum) * (value - inputMinimum) / inputSpan,
    outputMinimum,
    outputMaximum,
  );
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(value, 0) : 0;
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), upper);
}
