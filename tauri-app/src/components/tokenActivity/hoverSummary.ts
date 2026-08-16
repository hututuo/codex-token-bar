import type { ActivityDay } from "../../types/dashboard";
import type { ActivityMode } from "./types";
import { modelUsageCompactText } from "../modelUsagePresentation.ts";
import { modelCostSummaryText } from "./heatmap.ts";
import type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel.ts";

export function hoverSummary(
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
    const parsed = Date.parse(`${day.date}T00:00:00Z`);
    const eventStartUnix = Number.isFinite(parsed) ? parsed / 1000 : undefined;
    const rows = (day.modelBreakdowns ?? []).map((row) => ({
      ...row,
      eventStartUnix: row.eventStartUnix ?? eventStartUnix,
    }));
    return `${day.date} · ${formatTokens(day.tokens)} tokens · ${modelUsageCompactText(rows) ?? "暂无模型明细"}`;
  }
  if (mode === "modelCost") {
    return `${day.date} · ${modelCostSummaryText(day, fallbackModel, modelCostDataAvailable)}`;
  }

  return `${day.date} · ${formatTokens(day.tokens)} tokens · ${day.calls} calls`;
}

function formatOptionalPercent(value: number | null): string {
  return value === null ? "暂无" : formatPercent(value);
}

function formatTokens(value: number): string {
  if (value >= 100_000_000) {
    return `${(value / 100_000_000).toFixed(1)}亿`;
  }
  if (value >= 10_000) {
    return `${(value / 10_000).toFixed(1)}万`;
  }
  return value.toLocaleString("zh-CN");
}

function formatPercent(value: number): string {
  return `${Math.round(value * 100)}%`;
}
