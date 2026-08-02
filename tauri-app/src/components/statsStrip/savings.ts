import type { DashboardStats } from "../../types/usage";
import {
  modelAwareAPICostUSD,
  priceModelTitle,
  type OfficialAPIPriceModel,
} from "../../settings/quotaPriceModel.ts";

export {
  isOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  QUOTA_PRICE_MODEL_STORAGE_KEY,
} from "../../settings/quotaPriceModel.ts";

export interface LifetimeTokenBreakdown {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls?: number;
}

export interface LifetimeSavingsEstimate {
  apiEquivalentUSD: number;
  subscriptionCostUSD: number | null;
  netSavingsUSD: number | null;
  billingMonths: number;
  monthlyPlanUSD: number | null;
  normalizedPlanName: string;
  priceModel: OfficialAPIPriceModel;
  detectedModels: OfficialAPIPriceModel[];
  fallbackModelCalls: number;
  firstUsageAt: Date;
}

export interface LifetimeSavingsPresentation {
  valueText: string;
  labelText: string;
  helpText: string;
}

export function lifetimeBreakdownFromStats(stats: DashboardStats): LifetimeTokenBreakdown {
  const inputTokens = Math.max(0, stats.totalInputTokens ?? 0);
  return {
    inputTokens,
    cachedInputTokens: Math.max(0, Math.min(stats.totalCachedInputTokens ?? 0, inputTokens)),
    outputTokens: Math.max(0, stats.totalOutputTokens ?? 0),
    totalTokens: Math.max(0, stats.totalTokens),
    calls: Math.max(0, stats.totalCalls),
  };
}

export function estimateLifetimeSavings({
  breakdown,
  firstUsageAt,
  planLabel,
  priceModel,
  modelBreakdowns = [],
  now = new Date(),
}: {
  breakdown: LifetimeTokenBreakdown;
  firstUsageAt: string | null | undefined;
  planLabel: string;
  priceModel: OfficialAPIPriceModel;
  modelBreakdowns?: DashboardStats["modelBreakdowns"];
  now?: Date;
}): LifetimeSavingsEstimate | null {
  if (breakdown.totalTokens <= 0 || !firstUsageAt) return null;
  const first = new Date(firstUsageAt);
  if (!Number.isFinite(first.getTime()) || first.getTime() > now.getTime()) return null;
  const billingMonths = inclusiveCalendarMonths(first, now);
  if (billingMonths <= 0) return null;

  const automaticPrice = modelAwareAPICostUSD(modelBreakdowns, {
    inputTokens: breakdown.inputTokens,
    cachedInputTokens: breakdown.cachedInputTokens,
    outputTokens: breakdown.outputTokens,
    calls: Math.max(0, breakdown.calls ?? 0),
  }, priceModel);
  const apiEquivalentUSD = automaticPrice.costUSD;
  const monthlyPlanUSD = monthlyPlanPriceUSD(planLabel);
  const subscriptionCostUSD = monthlyPlanUSD === null ? null : monthlyPlanUSD * billingMonths;

  return {
    apiEquivalentUSD,
    subscriptionCostUSD,
    netSavingsUSD: subscriptionCostUSD === null ? null : apiEquivalentUSD - subscriptionCostUSD,
    billingMonths,
    monthlyPlanUSD,
    normalizedPlanName: planLabel.trim().toUpperCase() || "套餐未知",
    priceModel,
    detectedModels: automaticPrice.detectedModels,
    fallbackModelCalls: automaticPrice.fallbackCalls,
    firstUsageAt: first,
  };
}

export function inclusiveCalendarMonths(first: Date, now: Date): number {
  if (first.getTime() > now.getTime()) return 0;
  return Math.max(
    (now.getFullYear() - first.getFullYear()) * 12 + now.getMonth() - first.getMonth() + 1,
    0,
  );
}

export function monthlyPlanPriceUSD(planLabel: string): number | null {
  const normalized = planLabel.trim().toLowerCase();
  if (!normalized) return null;
  if (["enterprise", "edu", "health", "gov", "待读取", "unknown"].some((value) => normalized.includes(value))) {
    return null;
  }
  if (normalized.includes("business") || normalized.includes("team")) return 25;
  if (normalized.includes("plus")) return 20;
  if (normalized.includes("pro")) return 200;
  if (normalized === "free" || normalized.includes("免费")) return 0;
  return null;
}

export function savingsPresentation(estimate: LifetimeSavingsEstimate | null): LifetimeSavingsPresentation {
  if (!estimate) {
    return {
      valueText: "待读取",
      labelText: "累计薅到（估）",
      helpText: "等待精确 token、首次使用时间和套餐信息。",
    };
  }

  const modelTitle = estimate.detectedModels.length > 0
    ? estimate.detectedModels.map(priceModelTitle).join(" + ")
    : priceModelTitle(estimate.priceModel);
  const priceBasis = estimate.detectedModels.length > 0
    ? `按历史真实模型 ${modelTitle} 当前 API 单价自动估算${estimate.fallbackModelCalls > 0 ? `，另有 ${estimate.fallbackModelCalls} 次未知记录按 ${priceModelTitle(estimate.priceModel)} 回退` : ""}`
    : `缺少逐模型历史，按未知模型回退 ${modelTitle} 当前 API 单价估算`;
  if (estimate.netSavingsUSD !== null && estimate.subscriptionCostUSD !== null && estimate.monthlyPlanUSD !== null) {
    return {
      valueText: compactMoney(estimate.netSavingsUSD),
      labelText: "累计薅到（估）",
      helpText: `${priceBasis}：API 等值 ${fullMoney(estimate.apiEquivalentUSD)} − ${estimate.normalizedPlanName} ${estimate.billingMonths} 个月套餐成本 ${fullMoney(estimate.subscriptionCostUSD)}（${fullMoney(estimate.monthlyPlanUSD)}/月）= ${fullMoney(estimate.netSavingsUSD)}。历史套餐或模型变化未计入。`,
    };
  }

  return {
    valueText: compactMoney(estimate.apiEquivalentUSD),
    labelText: "API 等值（估）",
    helpText: `${priceBasis}为 ${fullMoney(estimate.apiEquivalentUSD)}；${estimate.normalizedPlanName} 没有公开固定月费，暂不计算净节省。`,
  };
}

function compactMoney(value: number): string {
  const sign = value < 0 ? "−" : "";
  const amount = Math.abs(value);
  if (amount >= 1_000_000) return `${sign}$${(amount / 1_000_000).toFixed(2)}m`;
  if (amount >= 10_000) return `${sign}$${(amount / 1_000).toFixed(1)}k`;
  if (amount >= 1_000) return `${sign}$${(amount / 1_000).toFixed(2)}k`;
  if (amount >= 100) return `${sign}$${amount.toFixed(0)}`;
  return `${sign}$${amount.toFixed(2)}`;
}

function fullMoney(value: number): string {
  return `${value < 0 ? "−" : ""}$${Math.abs(value).toFixed(2)}`;
}
