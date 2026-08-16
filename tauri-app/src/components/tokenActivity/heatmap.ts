import type { ActivityDay } from "../../types/dashboard";
import { clamp, formatPercent, formatTokens } from "../../utils/format.ts";
import type { ActivityMode, HeatmapDay } from "./types";
import { dominantModelColor, modelUsageCompactText } from "../modelUsagePresentation.ts";
import {
  floatingModelUsageMoneyText,
  floatingModelUsageValue,
  floatingTodayModelUsageItems,
} from "../../floating/floatingModelUsage.ts";
import type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel.ts";

export function buildHeatmapDays(
  days: ActivityDay[],
  mode: ActivityMode,
  fallbackModel: OfficialAPIPriceModel = "gpt56Sol",
  modelCostDataAvailable = true,
): HeatmapDay[] {
  let cumulative = 0;
  const rawValues = days.map((day, index) => {
    switch (mode) {
      case "weekly":
        return sumTokens(days.slice(Math.max(0, index - 6), index + 1));
      case "cumulative":
        cumulative += day.tokens;
        return cumulative > 0 ? cumulative : null;
      case "cache":
        return day.tokens > 0 ? day.cacheHitRate : null;
      case "quota":
        return day.sevenDayRemainingPercent ?? day.fiveHourRemainingPercent;
      case "model":
        return day.tokens > 0 ? day.tokens : null;
      case "modelCost":
        return modelCostUSD(day, fallbackModel, modelCostDataAvailable);
      case "daily":
      default:
        return day.tokens > 0 ? day.tokens : null;
    }
  });

  const tokenMax = Math.max(
    ...rawValues
      .filter((value): value is number => value !== null)
      .map((value) => Math.max(value, 0)),
    1,
  );

  return days.map((day, index) => {
    const value = rawValues[index];
    return {
      day,
      intensity: normalizeValue(value, tokenMax, mode),
    };
  });
}

export function cellColor(mode: ActivityMode, intensity: number): string {
  if (intensity <= 0) {
    return "var(--heatmap-empty)";
  }

  const color = mode === "cache" ? "#03a6c8" : mode === "quota" ? "var(--green)" : "var(--accent)";
  const weight = Math.round(14 + intensity * 78);
  return `color-mix(in srgb, ${color} ${weight}%, var(--heatmap-empty))`;
}

export function modelCellColor(day: ActivityDay, intensity: number): string {
  if (intensity <= 0) return "var(--heatmap-empty)";
  const color = dominantModelColor(dayModelRows(day)) ?? "#7a879e";
  const weight = Math.round(24 + intensity * 72);
  return `color-mix(in srgb, ${color} ${weight}%, var(--heatmap-empty))`;
}

export function modelCostCellBackground(
  day: ActivityDay,
  intensity: number,
  fallbackModel: OfficialAPIPriceModel = "gpt56Sol",
  modelCostDataAvailable = true,
): string {
  if (!modelCostDataAvailable) return "var(--heatmap-empty)";
  const items = floatingTodayModelUsageItems(dayModelRows(day), fallbackModel);
  const paid = items.filter((item) => (item.costUSD ?? 0) > 0);
  if (paid.length === 0) {
    const independent = items.find((item) => item.usesIndependentQuota);
    return independent
      ? `color-mix(in srgb, ${independent.color} 46%, var(--heatmap-empty))`
      : "var(--heatmap-empty)";
  }
  const total = paid.reduce((sum, item) => sum + (item.costUSD ?? 0), 0);
  if (total <= 0) return "var(--heatmap-empty)";
  const weight = Math.round(28 + intensity * 68);
  let cursor = 0;
  const stops: string[] = [];
  for (const item of paid) {
    const start = cursor;
    cursor = Math.min(100, cursor + ((item.costUSD ?? 0) / total) * 100);
    const color = `color-mix(in srgb, ${item.color} ${weight}%, var(--heatmap-empty))`;
    stops.push(`${color} ${start.toFixed(2)}%`, `${color} ${cursor.toFixed(2)}%`);
  }
  return `linear-gradient(90deg, ${stops.join(", ")})`;
}

export function cellLabel(
  day: ActivityDay,
  mode: ActivityMode,
  fallbackModel: OfficialAPIPriceModel = "gpt56Sol",
  modelCostDataAvailable = true,
): string {
  if (mode === "cache") {
    return `${day.date} · 命中率 ${formatPercent(day.cacheHitRate)} · ${day.calls} calls`;
  }
  if (mode === "quota") {
    return `${day.date} · 7d ${formatOptionalPercent(day.sevenDayRemainingPercent)} · 5h ${formatOptionalPercent(
      day.fiveHourRemainingPercent,
    )}`;
  }
  if (mode === "model") {
    return `${day.date} · ${formatTokens(day.tokens)} tokens · ${modelUsageCompactText(dayModelRows(day)) ?? "暂无模型明细"}`;
  }
  if (mode === "modelCost") {
    return `${day.date} · ${modelCostSummaryText(day, fallbackModel, modelCostDataAvailable)}`;
  }
  return `${day.date} · ${formatTokens(day.tokens)} tokens · ${day.calls} calls`;
}

export function modelCostUSD(
  day: ActivityDay,
  fallbackModel: OfficialAPIPriceModel,
  modelCostDataAvailable = true,
): number | null {
  if (!modelCostDataAvailable) return null;
  if (day.tokens > 0 && (!day.modelBreakdowns || day.modelBreakdowns.length === 0)) {
    return null;
  }
  return floatingTodayModelUsageItems(dayModelRows(day), fallbackModel)
    .reduce((total, item) => total + (item.costUSD ?? 0), 0);
}

export function modelCostSummaryText(
  day: ActivityDay,
  fallbackModel: OfficialAPIPriceModel,
  modelCostDataAvailable = true,
): string {
  const cost = modelCostUSD(day, fallbackModel, modelCostDataAvailable);
  if (cost === null) return "模型明细待读取";
  const items = floatingTodayModelUsageItems(dayModelRows(day), fallbackModel);
  if (items.length === 0) return "模型费用 $0.00 · 暂无模型用量";
  return [
    `模型费用 ${floatingModelUsageMoneyText(cost)}`,
    ...items.map((item) => `${item.label} ${floatingModelUsageValue(item, "cost")}`),
  ].join(" · ");
}

function normalizeValue(value: number | null, tokenMax: number, mode: ActivityMode): number {
  if (value === null || !Number.isFinite(value)) {
    return 0;
  }
  if (mode === "cache") {
    return clamp((value - 0.75) / 0.25, 0, 1);
  }
  if (mode === "quota") {
    return clamp((value - 0.55) / 0.45, 0, 1);
  }
  return clamp(value / tokenMax, 0, 1);
}

function formatOptionalPercent(value: number | null): string {
  return value === null ? "暂无" : formatPercent(value);
}

function sumTokens(days: ActivityDay[]): number {
  return days.reduce((total, day) => total + day.tokens, 0);
}

function dayModelRows(day: ActivityDay): NonNullable<ActivityDay["modelBreakdowns"]> {
  const parsed = Date.parse(`${day.date}T00:00:00Z`);
  const eventStartUnix = Number.isFinite(parsed) ? parsed / 1000 : undefined;
  return (day.modelBreakdowns ?? []).map((row) => ({
    ...row,
    eventStartUnix: row.eventStartUnix ?? eventStartUnix,
  }));
}
