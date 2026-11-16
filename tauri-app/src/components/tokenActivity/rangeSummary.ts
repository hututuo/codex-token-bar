import type { ActivityDay } from "../../types/dashboard";
import { formatPercent, formatTokens } from "../../utils/format.ts";
import type { ActivityMode } from "./types";
import { modelUsageCompactText } from "../modelUsagePresentation.ts";
import type { ModelTokenBreakdown } from "../../types/dashboard";
import {
  floatingModelUsageMoneyText,
  floatingModelUsageKnownCostUSD,
  floatingModelUsageValue,
  floatingTodayModelUsageItems,
  hasUnknownModelPrices,
} from "../../floating/floatingModelUsage.ts";
import type { OfficialAPIPriceModel } from "../../settings/quotaPriceModel.ts";
import { chartUsageSummary } from "../recentUsageChart/usageSnapshot";
import { recordedSummary } from "./recordedUsage";
import { quotaPercentNumber } from "../../multiClient/multiClientProduct";

export function summarizeRange(
  selectedDays: ActivityDay[],
  rangeStart: string | null,
  rangeEnd: string | null,
  mode: ActivityMode,
  fallbackModel: OfficialAPIPriceModel = "gpt56Sol",
  modelCostDataAvailable = true,
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
  if(["cache","model","modelCost"].includes(mode)&&selectedDays.every(day=>day.recordedUsage)){
    const usage=chartUsageSummary(selectedDays.flatMap(day=>day.recordedUsage?[day.recordedUsage]:[]),0,selectedDays.length-1);
    if(usage)return {hint:`${rangeStart} - ${rangeEnd}`,value:recordedSummary(usage,mode)};
  }
  if (mode === "cache") {
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: selectedDays.some(day => day.tokens > 0 && day.cacheHitRateKnown === false)
        ? `缓存字段不完整 · ${calls} calls`
        : `命中率均值 ${formatPercent(weightedCacheRate(selectedDays))} · ${calls} calls`,
    };
  }
  if (mode === "quota") {
    const period=selectedDays[0]?.quotaPeriod??"7d";
    const values=selectedDays.flatMap(day=>{
      const value=period==="5h"?day.fiveHourRemainingPercent:day.sevenDayRemainingPercent;
      return value==null?[]:[value];
    });
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: `${period} 有观测日均剩余 ${values.length?quotaPercentNumber(values.reduce((a,b)=>a+b,0)/values.length*100)+"%":"暂无"} · 覆盖 ${values.length}/${selectedDays.length} 天`,
    };
  }
  if (mode === "model") {
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: `${formatTokens(tokens)} · ${modelUsageCompactText(combineModelRows(selectedDays)) ?? "暂无模型明细"}`,
    };
  }
  if (mode === "modelCost") {
    if (!modelCostDataAvailable) {
      return {
        hint: `${rangeStart} - ${rangeEnd}`,
        value: "模型费用待读取",
      };
    }
    const missingDetail = selectedDays.some((day) => (
      day.tokens > 0 && (!day.modelBreakdowns || day.modelBreakdowns.length === 0)
    ));
    if (missingDetail) {
      return {
        hint: `${rangeStart} - ${rangeEnd}`,
        value: "所选日期模型明细待读取",
      };
    }
    const items = floatingTodayModelUsageItems(combineModelRows(selectedDays), fallbackModel, { mergeAutoReview: false });
    const total = floatingModelUsageKnownCostUSD(items);
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: [
        total === null
          ? "已知价格小计 —"
          : `${hasUnknownModelPrices(items) ? "已知价格小计" : "模型费用"} ${floatingModelUsageMoneyText(total)}`,
        ...items.map((item) => `${item.label} ${floatingModelUsageValue(item, "cost")}`),
      ].join(" · "),
    };
  }
  return {
    hint: `${rangeStart} - ${rangeEnd}`,
    value: `${formatTokens(tokens)} tokens · ${calls} calls`,
  };
}

function combineModelRows(days: ActivityDay[]): ModelTokenBreakdown[] {
  return days.flatMap((day) => (day.modelBreakdowns ?? []).map((row) => ({
    ...row,
    // Daily aggregates have no event-level timestamp. Use the UTC day start
    // as the stable compatibility boundary; five-minute chart points retain
    // their exact bucket timestamps for precise attribution.
    eventStartUnix: row.eventStartUnix ?? dayStartUnix(day.date),
  })));
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
  const recorded = days.filter(day => day.tokens > 0);
  if (recorded.length && recorded.every(day => day.cacheInputTokens !== undefined && day.cacheHitRateKnown !== false)) {
    const inputs = recorded.reduce((n,day)=>n+(day.cacheInputTokens ?? 0),0);
    return inputs > 0 ? recorded.reduce((n,day)=>n+(day.cacheReadTokens ?? 0),0)/inputs : 0;
  }
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

function dayStartUnix(date: string): number {
  const parsed = Date.parse(`${date}T00:00:00Z`);
  return Number.isFinite(parsed) ? parsed / 1000 : Number.NaN;
}
