import type { ActivityDay } from "../../types/dashboard";
import { clamp, formatPercent, formatTokens } from "../../utils/format";
import type { ActivityMode, HeatmapDay } from "./types";

export function buildHeatmapDays(days: ActivityDay[], mode: ActivityMode): HeatmapDay[] {
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

export function cellLabel(day: ActivityDay, mode: ActivityMode): string {
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
