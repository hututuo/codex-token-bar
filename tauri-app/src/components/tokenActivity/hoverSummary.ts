import type { ActivityDay } from "../../types/dashboard";
import type { ActivityMode } from "./types";

export function hoverSummary(day: ActivityDay, mode: ActivityMode): string {
  if (mode === "cache") {
    return `${day.date} · 命中率 ${formatPercent(day.cacheHitRate)} · ${day.calls} calls`;
  }

  if (mode === "quota") {
    return `${day.date} · 7d ${formatOptionalPercent(day.sevenDayRemainingPercent)} · 5h ${formatOptionalPercent(
      day.fiveHourRemainingPercent,
    )}`;
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
