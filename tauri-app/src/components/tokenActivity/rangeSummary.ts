import type { ActivityDay } from "../../types/dashboard";
import { formatPercent, formatTokens } from "../../utils/format";
import type { ActivityMode } from "./types";

export function summarizeRange(
  selectedDays: ActivityDay[],
  rangeStart: string | null,
  rangeEnd: string | null,
  mode: ActivityMode,
) {
  if (rangeStart === null) {
    return {
      hint: "点击开始和结束日期，可显示范围总计",
      value: "总计",
    };
  }
  if (rangeEnd === null) {
    return {
      hint: `${rangeStart} 已选中，再点一个结束日期`,
      value: "等待结束日期",
    };
  }

  const tokens = sumTokens(selectedDays);
  const calls = selectedDays.reduce((total, day) => total + day.calls, 0);
  if (mode === "cache") {
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: `命中率均值 ${formatPercent(weightedCacheRate(selectedDays))} · ${calls} calls`,
    };
  }
  if (mode === "quota") {
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: `7d ${formatOptionalPercent(averageQuota(selectedDays, "sevenDayRemainingPercent"))} · 5h ${formatOptionalPercent(
        averageQuota(selectedDays, "fiveHourRemainingPercent"),
      )}`,
    };
  }
  return {
    hint: `${rangeStart} - ${rangeEnd}`,
    value: `${formatTokens(tokens)} tokens · ${calls} calls`,
  };
}

export function isInRange(date: string, rangeStart: string | null, rangeEnd: string | null): boolean {
  if (rangeStart === null) {
    return false;
  }
  if (rangeEnd === null) {
    return date === rangeStart;
  }
  return date >= rangeStart && date <= rangeEnd;
}

function weightedCacheRate(days: ActivityDay[]): number {
  const activeDays = days.filter((day) => day.tokens > 0);
  const weightedCalls = activeDays.reduce((total, day) => total + day.calls, 0);
  if (weightedCalls === 0) {
    return 0;
  }
  return (
    activeDays.reduce((total, day) => total + day.cacheHitRate * day.calls, 0) / weightedCalls
  );
}

function averageQuota(
  days: ActivityDay[],
  key: "fiveHourRemainingPercent" | "sevenDayRemainingPercent",
): number | null {
  const values = days
    .map((day) => day[key])
    .filter((value): value is number => value !== null && Number.isFinite(value));
  if (values.length === 0) {
    return null;
  }
  return values.reduce((total, value) => total + value, 0) / values.length;
}

function formatOptionalPercent(value: number | null): string {
  return value === null ? "暂无" : formatPercent(value);
}

function sumTokens(days: ActivityDay[]): number {
  return days.reduce((total, day) => total + day.tokens, 0);
}
