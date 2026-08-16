import type { DashboardStats, ModelTokenBreakdown, RecentUsagePoint } from "../../types/usage";
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

const SEVEN_DAY_SECONDS = 7 * 24 * 60 * 60;

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
  excludedModels: string[];
  excludedCalls: number;
  firstUsageAt: Date;
}

export interface LifetimeSavingsPresentation {
  valueText: string;
  labelText: string;
  helpText: string;
}

export interface Recent7dSavingsEstimate {
  apiEquivalentUSD: number;
  /** Whether every non-empty five-minute point had model coverage. */
  quality: "measured" | "estimated";
  /** Human-readable source used while the precise model scan is pending. */
  estimateSource?: string;
  priceModel: OfficialAPIPriceModel;
  modelBreakdowns: ModelTokenBreakdown[];
  detectedModels: OfficialAPIPriceModel[];
  fallbackModelCalls: number;
  excludedModels: string[];
  excludedCalls: number;
  periodStartUnix: number;
  resetAtUnix: number;
  pointCount: number;
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
    excludedModels: automaticPrice.excludedModels,
    excludedCalls: automaticPrice.excludedCalls,
    firstUsageAt: first,
  };
}

/**
 * Estimate API-equivalent spend for the currently observed 7-day quota cycle.
 *
 * The reset boundary is authoritative. The native recentUsage24h compatibility
 * field is a 30-day five-minute canvas. While precise model attribution is
 * still loading, keep the numeric five-minute point and price it as an
 * explicitly unknown model instead of turning the entire 7d row into a blank.
 * The UI marks that result as estimated until the precise model buckets arrive.
 */
export function estimateRecent7dAPICost({
  points,
  resetAtUnix,
  priceModel,
}: {
  points?: RecentUsagePoint[] | null;
  resetAtUnix?: number | null;
  priceModel: OfficialAPIPriceModel;
}): Recent7dSavingsEstimate | null {
  if (typeof resetAtUnix !== "number" || !Number.isFinite(resetAtUnix)) return null;

  const periodStartUnix = resetAtUnix - SEVEN_DAY_SECONDS;
  const cyclePoints = (points ?? []).filter((point) => (
    Number.isFinite(point.startUnix)
      && point.startUnix >= periodStartUnix
      && point.startUnix < resetAtUnix
  ));
  const usagePoints = cyclePoints.filter(hasUsage);
  if (usagePoints.length === 0) return null;

  const aggregate = {
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    calls: 0,
  };
  const rows: Array<{
    model: string | null;
    eventStartUnix?: number;
    breakdown: {
      inputTokens: number;
      cachedInputTokens: number;
      outputTokens: number;
      calls: number;
    };
  }> = [];
  let quality: Recent7dSavingsEstimate["quality"] = "measured";
  let estimateSource: string | undefined;

  for (const point of usagePoints) {
    const pointBreakdown = safePointBreakdown(point);
    const pointRows = Array.isArray(point.modelBreakdowns)
      ? point.modelBreakdowns.map((row) => ({
      model: row.model,
      eventStartUnix: row.eventStartUnix ?? point.startUnix,
      breakdown: safeBreakdown(row.breakdown),
      }))
      : [];
    const covered = pointRows.reduce((total, row) => addBreakdowns(total, row.breakdown), emptyBreakdown());

    aggregate.inputTokens += pointBreakdown.inputTokens;
    aggregate.cachedInputTokens += pointBreakdown.cachedInputTokens;
    aggregate.outputTokens += pointBreakdown.outputTokens;
    aggregate.calls += pointBreakdown.calls;
    if (sameBreakdown(covered, pointBreakdown)) {
      rows.push(...pointRows);
    } else {
      // Keep the quick estimate numerically complete, but do not pretend that
      // a point without model rows has a known model. The pricing layer will
      // use the selected fallback model for this synthetic row.
      quality = "estimated";
      estimateSource = "5分钟桶用量缓存";
      rows.push({
        model: null,
        eventStartUnix: point.startUnix,
        breakdown: pointBreakdown,
      });
    }
  }

  const automaticPrice = modelAwareAPICostUSD(rows, aggregate, priceModel);
  return {
    apiEquivalentUSD: automaticPrice.costUSD,
    quality,
    ...(estimateSource ? { estimateSource } : {}),
    priceModel,
    modelBreakdowns: rows.map((row) => ({
      model: row.model,
      eventStartUnix: row.eventStartUnix,
      breakdown: {
        ...row.breakdown,
        totalTokens: row.breakdown.inputTokens + row.breakdown.outputTokens,
      },
    })),
    detectedModels: automaticPrice.detectedModels,
    fallbackModelCalls: automaticPrice.fallbackCalls,
    excludedModels: automaticPrice.excludedModels,
    excludedCalls: automaticPrice.excludedCalls,
    periodStartUnix,
    resetAtUnix,
    pointCount: usagePoints.length,
  };
}

type CostBreakdown = {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  calls: number;
};

function hasUsage(point: RecentUsagePoint): boolean {
  const breakdown = safePointBreakdown(point);
  return breakdown.inputTokens > 0
    || breakdown.cachedInputTokens > 0
    || breakdown.outputTokens > 0
    || breakdown.calls > 0
    || finiteNonnegative(point.tokens) > 0;
}

function safePointBreakdown(point: RecentUsagePoint): CostBreakdown {
  return safeBreakdown({
    inputTokens: point.inputTokens,
    cachedInputTokens: point.cachedInputTokens,
    outputTokens: point.outputTokens,
    calls: point.calls,
  });
}

function safeBreakdown(breakdown: Partial<CostBreakdown> | null | undefined): CostBreakdown {
  const inputTokens = finiteNonnegative(breakdown?.inputTokens);
  return {
    inputTokens,
    cachedInputTokens: Math.min(finiteNonnegative(breakdown?.cachedInputTokens), inputTokens),
    outputTokens: finiteNonnegative(breakdown?.outputTokens),
    calls: finiteNonnegative(breakdown?.calls),
  };
}

function emptyBreakdown(): CostBreakdown {
  return { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 };
}

function addBreakdowns(total: CostBreakdown, next: CostBreakdown): CostBreakdown {
  return {
    inputTokens: total.inputTokens + next.inputTokens,
    cachedInputTokens: total.cachedInputTokens + next.cachedInputTokens,
    outputTokens: total.outputTokens + next.outputTokens,
    calls: total.calls + next.calls,
  };
}

function sameBreakdown(left: CostBreakdown, right: CostBreakdown): boolean {
  return left.inputTokens === right.inputTokens
    && left.cachedInputTokens === right.cachedInputTokens
    && left.outputTokens === right.outputTokens
    && left.calls === right.calls;
}

function finiteNonnegative(value: number | null | undefined): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
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
  const hasOnlyExcludedModels = estimate.detectedModels.length === 0
    && estimate.fallbackModelCalls === 0
    && estimate.excludedModels.length > 0;
  const priceBasis = hasOnlyExcludedModels
    ? `${estimate.excludedModels.join("、")} ${estimate.excludedCalls} 次调用属于独立额度，不参与 API 等值`
    : estimate.detectedModels.length > 0
    ? `按历史真实模型 ${modelTitle} 当前 API 单价自动估算${estimate.fallbackModelCalls > 0 ? `，另有 ${estimate.fallbackModelCalls} 次未知记录按 ${priceModelTitle(estimate.priceModel)} 回退` : ""}`
    : `缺少逐模型历史，按未知模型回退 ${modelTitle} 当前 API 单价估算`;
  const excludedNote = !hasOnlyExcludedModels && estimate.excludedModels.length > 0
    ? `；${estimate.excludedModels.join("、")} ${estimate.excludedCalls} 次调用属于独立额度，不参与 API 等值`
    : "";
  if (estimate.netSavingsUSD !== null && estimate.subscriptionCostUSD !== null && estimate.monthlyPlanUSD !== null) {
    return {
      valueText: compactMoney(estimate.netSavingsUSD),
      labelText: "累计薅到（估）",
      helpText: `${priceBasis}${excludedNote}：API 等值 ${fullMoney(estimate.apiEquivalentUSD)} − ${estimate.normalizedPlanName} ${estimate.billingMonths} 个月套餐成本 ${fullMoney(estimate.subscriptionCostUSD)}（${fullMoney(estimate.monthlyPlanUSD)}/月）= ${fullMoney(estimate.netSavingsUSD)}。历史套餐或模型变化未计入。`,
    };
  }

  return {
    valueText: compactMoney(estimate.apiEquivalentUSD),
    labelText: "API 等值（估）",
    helpText: `${priceBasis}${excludedNote}，API 等值为 ${fullMoney(estimate.apiEquivalentUSD)}；${estimate.normalizedPlanName} 没有公开固定月费，暂不计算净节省。`,
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
