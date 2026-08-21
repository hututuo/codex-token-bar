import type { UsageRefreshSettings } from "../types/settings";

export const DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS = 150;
export const DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES = 10;
export const DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES = 30;

export const USAGE_LIGHT_REFRESH_INTERVAL_OPTIONS = [
  { valueSeconds: 60, label: "1 分钟" },
  { valueSeconds: 150, label: "2.5 分钟" },
  { valueSeconds: 300, label: "5 分钟" },
  { valueSeconds: 600, label: "10 分钟" },
] as const;

export const USAGE_AGGREGATE_INTERVAL_OPTIONS = [
  { valueMinutes: 5, label: "5 分钟" },
  { valueMinutes: 10, label: "10 分钟" },
  { valueMinutes: 15, label: "15 分钟" },
  { valueMinutes: 30, label: "30 分钟" },
] as const;

// Numeric aliases mirror the native policy vocabulary and are convenient for
// schedulers that do not need presentation labels.
export const lightRefreshIntervalOptions = [60, 150, 300, 600] as const;
export const aggregateIntervalOptions = [5, 10, 15, 30] as const;

const ALLOWED_LIGHT_REFRESH_INTERVAL_SECONDS = new Set<number>(
  USAGE_LIGHT_REFRESH_INTERVAL_OPTIONS.map((option) => option.valueSeconds),
);
const ALLOWED_AGGREGATE_INTERVAL_MINUTES = new Set<number>(
  USAGE_AGGREGATE_INTERVAL_OPTIONS.map((option) => option.valueMinutes),
);

export const DEFAULT_USAGE_REFRESH_SETTINGS: UsageRefreshSettings = {
  usageLightRefreshIntervalSeconds: DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS,
  usageVisibleAggregateIntervalMinutes: DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES,
  usageBackgroundAggregateIntervalMinutes: DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
};

export function sanitizeUsageLightRefreshIntervalSeconds(value: unknown): number {
  return typeof value === "number"
    && Number.isFinite(value)
    && ALLOWED_LIGHT_REFRESH_INTERVAL_SECONDS.has(value)
    ? value
    : DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS;
}

export const normalizedLightRefreshIntervalSeconds = sanitizeUsageLightRefreshIntervalSeconds;

export function sanitizeUsageAggregateIntervalMinutes(value: unknown): number {
  return typeof value === "number"
    && Number.isFinite(value)
    && ALLOWED_AGGREGATE_INTERVAL_MINUTES.has(value)
    ? value
    : DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES;
}

export const normalizedVisibleAggregateIntervalMinutes = sanitizeUsageAggregateIntervalMinutes;
export const normalizedAggregateIntervalMinutes = sanitizeUsageAggregateIntervalMinutes;

export function sanitizeUsageBackgroundAggregateIntervalMinutes(value: unknown): number {
  return typeof value === "number"
    && Number.isFinite(value)
    && ALLOWED_AGGREGATE_INTERVAL_MINUTES.has(value)
    ? value
    : DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES;
}

export const normalizedBackgroundAggregateIntervalMinutes = sanitizeUsageBackgroundAggregateIntervalMinutes;

export function sanitizeUsageRefreshSettings(
  settings: Partial<UsageRefreshSettings> | null | undefined,
): UsageRefreshSettings {
  return {
    usageLightRefreshIntervalSeconds: sanitizeUsageLightRefreshIntervalSeconds(
      settings?.usageLightRefreshIntervalSeconds,
    ),
    usageVisibleAggregateIntervalMinutes: sanitizeUsageAggregateIntervalMinutes(
      settings?.usageVisibleAggregateIntervalMinutes,
    ),
    usageBackgroundAggregateIntervalMinutes: sanitizeUsageBackgroundAggregateIntervalMinutes(
      settings?.usageBackgroundAggregateIntervalMinutes,
    ),
  };
}

export function usageLightRefreshIntervalLabel(value: unknown): string {
  const seconds = sanitizeUsageLightRefreshIntervalSeconds(value);
  return USAGE_LIGHT_REFRESH_INTERVAL_OPTIONS.find((option) => option.valueSeconds === seconds)?.label
    ?? "2.5 分钟";
}

export function usageAggregateIntervalLabel(value: unknown): string {
  const minutes = sanitizeUsageAggregateIntervalMinutes(value);
  return USAGE_AGGREGATE_INTERVAL_OPTIONS.find((option) => option.valueMinutes === minutes)?.label
    ?? "5 分钟";
}
