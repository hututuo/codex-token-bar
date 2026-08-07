import {
  modelUsageColor,
  modelUsageKey,
  modelUsageLabel,
  type ModelUsageRowLike,
} from "../components/modelUsagePresentation.ts";
import {
  detectedOfficialAPIPriceModel,
  independentQuotaModelName,
  officialAPICostUSD,
  type OfficialAPIPriceModel,
} from "../settings/quotaPriceModel.ts";

export type FloatingModelUsagePage = "share" | "cost";

export interface FloatingModelUsageItem {
  key: string;
  label: string;
  tokens: number;
  share: number;
  costUSD: number | null;
  usesIndependentQuota: boolean;
  color: string;
}

interface CombinedModelUsage {
  model: string | null;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls: number;
}

export function floatingTodayModelUsageItems(
  rows: ModelUsageRowLike[] | null | undefined,
  fallbackModel: OfficialAPIPriceModel,
): FloatingModelUsageItem[] {
  const grouped = new Map<string, CombinedModelUsage>();
  for (const row of rows ?? []) {
    const key = modelUsageKey(row.model);
    const current = grouped.get(key) ?? {
      model: row.model,
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      calls: 0,
    };
    current.inputTokens += finiteNonnegative(row.breakdown.inputTokens);
    current.cachedInputTokens += finiteNonnegative(row.breakdown.cachedInputTokens);
    current.outputTokens += finiteNonnegative(row.breakdown.outputTokens);
    current.totalTokens += Number.isFinite(row.breakdown.totalTokens)
      ? finiteNonnegative(row.breakdown.totalTokens)
      : finiteNonnegative(row.breakdown.inputTokens) + finiteNonnegative(row.breakdown.outputTokens);
    current.calls += finiteNonnegative(row.breakdown.calls);
    grouped.set(key, current);
  }
  const total = [...grouped.values()].reduce((sum, row) => sum + row.totalTokens, 0);
  if (total <= 0) return [];
  return [...grouped.entries()].map(([key, row]) => {
    const usesIndependentQuota = independentQuotaModelName(row.model) !== null;
    const priceModel = detectedOfficialAPIPriceModel(row.model) ?? fallbackModel;
    return {
      key,
      label: modelUsageLabel(row.model),
      tokens: row.totalTokens,
      share: row.totalTokens / total,
      costUSD: usesIndependentQuota
        ? null
        : officialAPICostUSD(
            row.inputTokens,
            row.cachedInputTokens,
            row.outputTokens,
            priceModel,
          ),
      usesIndependentQuota,
      color: modelUsageColor(key),
    };
  }).sort((left, right) => right.tokens - left.tokens || left.label.localeCompare(right.label));
}

export function floatingModelUsageValue(
  item: FloatingModelUsageItem,
  page: FloatingModelUsagePage,
): string {
  if (page === "share") return `${Math.round(item.share * 100)}%`;
  if (item.usesIndependentQuota) return "独立";
  return moneyText(item.costUSD ?? 0);
}

export function floatingModelUsageAccessibilityText(
  page: FloatingModelUsagePage,
  rows: ModelUsageRowLike[] | null | undefined,
  fallbackModel: OfficialAPIPriceModel,
): string {
  const items = floatingTodayModelUsageItems(rows, fallbackModel);
  if (items.length === 0) return "今日模型待读取";
  const title = page === "share" ? "占比" : "费用";
  return `今日模型${title}：${items.map((item) => `${item.label} ${floatingModelUsageValue(item, page)}`).join("，")}`;
}

function moneyText(value: number): string {
  if (value >= 100) return `$${value.toFixed(0)}`;
  if (value >= 10) return `$${value.toFixed(1)}`;
  return `$${value.toFixed(2)}`;
}

function finiteNonnegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
}
