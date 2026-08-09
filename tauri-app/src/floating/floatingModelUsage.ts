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

// Keep this list in lockstep with the Swift compact surface. Spark is not a
// default paid model because its quota is independent; it is added only when
// the source actually reports Spark usage.
export const FLOATING_DEFAULT_MODEL_KEYS = [
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.3-codex",
] as const;

const FLOATING_DEFAULT_MODEL_ORDER: ReadonlyMap<string, number> = new Map(
  FLOATING_DEFAULT_MODEL_KEYS.map((key, index) => [key, index]),
);

export function floatingTodayModelUsageItems(
  rows: ModelUsageRowLike[] | null | undefined,
  fallbackModel: OfficialAPIPriceModel,
  options: { showPlaceholders?: boolean } = {},
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
  if (total <= 0 && !options.showPlaceholders) return [];
  if (options.showPlaceholders) {
    for (const key of FLOATING_DEFAULT_MODEL_KEYS) {
      if (!grouped.has(key)) {
        grouped.set(key, {
          model: key,
          inputTokens: 0,
          cachedInputTokens: 0,
          outputTokens: 0,
          totalTokens: 0,
          calls: 0,
        });
      }
    }
  }
  return [...grouped.entries()].map(([key, row]) => {
    const usesIndependentQuota = independentQuotaModelName(row.model) !== null;
    const priceModel = detectedOfficialAPIPriceModel(row.model) ?? fallbackModel;
    const costUSD = usesIndependentQuota
      ? null
      : officialAPICostUSD(
        row.inputTokens,
        row.cachedInputTokens,
        row.outputTokens,
        priceModel,
      );
    return {
      key,
      label: modelUsageLabel(row.model),
      tokens: row.totalTokens,
      share: total > 0 ? row.totalTokens / total : 0,
      costUSD,
      usesIndependentQuota,
      color: modelUsageColor(key),
    };
  }).sort((left, right) => {
    const leftUsed = left.tokens > 0;
    const rightUsed = right.tokens > 0;
    if (leftUsed !== rightUsed) return leftUsed ? -1 : 1;

    // Both pages consume this one order. Paid models sort by today's dollar
    // estimate; independent-quota Spark has no dollar value but stays ahead
    // of zero placeholders when it was actually used.
    const leftCost = left.costUSD ?? 0;
    const rightCost = right.costUSD ?? 0;
    if (leftCost !== rightCost) return rightCost - leftCost;
    if (left.usesIndependentQuota !== right.usesIndependentQuota) {
      return left.usesIndependentQuota ? 1 : -1;
    }
    const leftDefaultIndex = FLOATING_DEFAULT_MODEL_ORDER.get(left.key) ?? FLOATING_DEFAULT_MODEL_KEYS.length;
    const rightDefaultIndex = FLOATING_DEFAULT_MODEL_ORDER.get(right.key) ?? FLOATING_DEFAULT_MODEL_KEYS.length;
    if (leftDefaultIndex !== rightDefaultIndex) return leftDefaultIndex - rightDefaultIndex;
    return left.key.localeCompare(right.key);
  });
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
  options: { showPlaceholders?: boolean } = {},
): string {
  const items = floatingTodayModelUsageItems(rows, fallbackModel, options);
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
