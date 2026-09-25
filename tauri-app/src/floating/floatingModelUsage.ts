import {
  modelUsageColor,
  modelUsageKey,
  floatingModelUsageKey,
  modelUsageLabel,
  type ModelUsageRowLike,
} from "../components/modelUsagePresentation.ts";
import {
  independentQuotaReferenceCostUSD,
  independentQuotaModelName,
  modelAwareAPICostUSD,
  type OfficialAPIPriceModel,
} from "../settings/quotaPriceModel.ts";
import { formatTokens } from "../utils/format.ts";
import type { ModelTokenBreakdown } from "../types/usage.ts";

export type FloatingModelUsagePage = "share" | "cost";

export interface FloatingModelUsageItem {
  key: string;
  label: string;
  tokens: number;
  share: number;
  costUSD: number | null;
  usesIndependentQuota: boolean;
  referenceCostUSD: number | null;
  color: string;
}

export const FLOATING_MODEL_USAGE_VISIBLE_LIMIT = 4;
export const FLOATING_MODEL_USAGE_MINIMUM_COUNT = 4;
export const DASHBOARD_PRIMARY_MODEL_KEYS = [
  "gpt-6-astra",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
] as const;

interface CombinedModelUsage {
  costUSD: number;
  priceUnknown: boolean;
  model: string | null;
  eventStartUnix?: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  totalTokens: number;
  calls: number;
}

// Keep this list in lockstep with the Swift compact surface. These are the
// placeholder priority keys; only enough zero rows are added to reach four
// total visible models. Spark is not a default paid model because its quota is
// independent; it is added only when the source actually reports Spark usage.
export const FLOATING_DEFAULT_MODEL_KEYS = [
  "gpt-6-astra",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
] as const;

/** UI-only values for the first-run paging guide while precise model rows load. */
export const FLOATING_GUIDE_DEMO_MODEL_BREAKDOWNS: ModelTokenBreakdown[] = [
  {
    model: "gpt-5.6-sol",
    breakdown: {
      inputTokens: 4_400_000,
      cachedInputTokens: 2_300_000,
      outputTokens: 800_000,
      totalTokens: 5_200_000,
      calls: 18,
    },
  },
  {
    model: "gpt-5.6-luna",
    breakdown: {
      inputTokens: 2_800_000,
      cachedInputTokens: 1_200_000,
      outputTokens: 500_000,
      totalTokens: 3_300_000,
      calls: 11,
    },
  },
  {
    model: "gpt-5.6-terra",
    breakdown: {
      inputTokens: 1_200_000,
      cachedInputTokens: 600_000,
      outputTokens: 300_000,
      totalTokens: 1_500_000,
      calls: 6,
    },
  },
];

const FLOATING_DEFAULT_MODEL_ORDER: ReadonlyMap<string, number> = new Map(
  FLOATING_DEFAULT_MODEL_KEYS.map((key, index) => [key, index]),
);

export function floatingTodayModelUsageItems(
  rows: ModelUsageRowLike[] | null | undefined,
  fallbackModel: OfficialAPIPriceModel,
  options: { showPlaceholders?: boolean; mergeAutoReview?: boolean } = {},
): FloatingModelUsageItem[] {
  const grouped = new Map<string, CombinedModelUsage>();
  for (const row of rows ?? []) {
    const key = options.mergeAutoReview === false
      ? modelUsageKey(row.model, row.eventStartUnix)
      : floatingModelUsageKey(row.model, row.eventStartUnix);
    const current = grouped.get(key) ?? {
      costUSD: 0,
      priceUnknown: false,
      model: row.model,
      eventStartUnix: row.eventStartUnix,
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      calls: 0,
    };
    const priceRow = { model: row.model, eventStartUnix: row.eventStartUnix, breakdown: {
      inputTokens: finiteNonnegative(row.breakdown.inputTokens),
      cachedInputTokens: finiteNonnegative(row.breakdown.cachedInputTokens),
      outputTokens: finiteNonnegative(row.breakdown.outputTokens), calls: finiteNonnegative(row.breakdown.calls),
    } };
    const price = modelAwareAPICostUSD([priceRow], priceRow.breakdown, fallbackModel);
    current.costUSD += price.costUSD;
    // An anonymous row still carries real tokens, but has no model price.
    // Keep the accounting fallback out of per-model presentation.
    current.priceUnknown ||= !row.model?.trim() || price.unpricedModels.length > 0;
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
      if (grouped.size >= FLOATING_MODEL_USAGE_MINIMUM_COUNT) break;
      if (!grouped.has(key)) {
        grouped.set(key, {
          costUSD: 0,
          priceUnknown: false,
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
    const costUSD = usesIndependentQuota || row.priceUnknown ? null : row.costUSD;
    const referenceCostUSD = independentQuotaReferenceCostUSD(
      row.model,
      row.inputTokens,
      row.cachedInputTokens,
      row.outputTokens,
    );
    return {
      key,
      label: modelUsageLabel(key),
      tokens: row.totalTokens,
      share: total > 0 ? row.totalTokens / total : 0,
      costUSD,
      usesIndependentQuota,
      referenceCostUSD,
      color: modelUsageColor(key),
    };
  }).sort((left, right) => {
    const leftUsed = left.tokens > 0;
    const rightUsed = right.tokens > 0;
    if (leftUsed !== rightUsed) return leftUsed ? -1 : 1;

    // Both pages consume this one order. Paid models sort by today's dollar
    // estimate; independent-quota Spark has no billable dollar value in the
    // primary total, so its separate reference price does not affect order.
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

export function floatingModelUsagePageSizes(itemCount: number): number[] {
  const count = Math.max(0, Math.floor(itemCount));
  if (count === 0) return [];
  if (count <= FLOATING_MODEL_USAGE_VISIBLE_LIMIT) return [count];

  const pageCount = Math.ceil(count / FLOATING_MODEL_USAGE_VISIBLE_LIMIT);
  const baseSize = Math.floor(count / pageCount);
  const remainder = count % pageCount;
  return Array.from({ length: pageCount }, (_, index) => baseSize + (index < remainder ? 1 : 0));
}

export function floatingModelUsagePageCount(
  page: FloatingModelUsagePage,
  items: FloatingModelUsageItem[],
): number {
  if (page !== "cost" || items.length === 0) return 1;
  return Math.max(1, floatingModelUsagePageSizes(items.length).length);
}

export function floatingModelUsagePageItems(
  page: FloatingModelUsagePage,
  items: FloatingModelUsageItem[],
  pageIndex: number,
): FloatingModelUsageItem[] {
  if (page !== "cost") return items.slice(0, FLOATING_MODEL_USAGE_VISIBLE_LIMIT);

  const sizes = floatingModelUsagePageSizes(items.length);
  if (sizes.length === 0) return [];
  const safePageIndex = Math.min(Math.max(Math.floor(pageIndex), 0), sizes.length - 1);
  const start = sizes.slice(0, safePageIndex).reduce((sum, size) => sum + size, 0);
  return items.slice(start, start + sizes[safePageIndex]);
}

export function floatingModelUsageValue(
  item: FloatingModelUsageItem,
  page: FloatingModelUsagePage,
): string {
  if (page === "share") {
    const percent = Math.max(0, item.share) * 100;
    if (percent > 0 && percent < 0.1) return "<0.1%";
    if (percent > 0 && percent < 10) return `${percent.toFixed(1)}%`;
    return `${Math.round(percent)}%`;
  }
  if (item.usesIndependentQuota) {
    const referenceCost = item.referenceCostUSD === null
      ? "—"
      : floatingModelUsageMoneyText(item.referenceCostUSD);
    return `${referenceCost}（不计入总计）`;
  }
  return item.costUSD === null ? "价格未知" : floatingModelUsageMoneyText(item.costUSD);
}

export function hasUnknownModelPrices(items: FloatingModelUsageItem[]): boolean {
  return items.some((item) => item.tokens > 0 && !item.usesIndependentQuota && item.costUSD === null);
}

/**
 * Return the known-price subtotal without turning an all-unknown set into
 * `$0.00`.  A null result means that at least one billable model is present,
 * but none of the billable models has a compatible price. Independent-quota
 * models (for example Spark) remain outside the API subtotal and therefore do
 * not make an otherwise empty subtotal unknown.
 */
export function floatingModelUsageKnownCostUSD(
  items: FloatingModelUsageItem[],
): number | null {
  const billable = items.filter((item) => item.tokens > 0 && !item.usesIndependentQuota);
  const known = billable.filter((item) => item.costUSD !== null);
  if (billable.some((item) => item.costUSD === null) && known.length === 0) {
    return null;
  }
  return known.reduce((sum, item) => sum + (item.costUSD ?? 0), 0);
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

export function dashboardPrimaryModelUsageItems(
  items: FloatingModelUsageItem[],
): FloatingModelUsageItem[] {
  const byKey = new Map(items.map((item) => [item.key, item]));
  return DASHBOARD_PRIMARY_MODEL_KEYS.map((key) => (
    byKey.get(key) ?? dashboardModelUsagePlaceholder(key)
  ));
}

export function dashboardSecondaryModelUsageItems(
  items: FloatingModelUsageItem[],
): FloatingModelUsageItem[] {
  const primaryKeys = new Set<string>(DASHBOARD_PRIMARY_MODEL_KEYS);
  return items.filter((item) => !primaryKeys.has(item.key) && item.tokens > 0);
}

export function floatingModelUsageOverflowText(
  items: FloatingModelUsageItem[],
  visibleLimit = FLOATING_MODEL_USAGE_VISIBLE_LIMIT,
): string | null {
  const hiddenItems = items.slice(Math.max(visibleLimit, 0));
  if (hiddenItems.length === 0) return null;
  const details = hiddenItems.map((item) => {
    const cost = floatingModelUsageValue(item, "cost");
    return `${item.label} · ${formatTokens(item.tokens)} tokens · 占比 ${detailedShareText(item.share)} · ${cost}`;
  });
  return ["更多模型", ...details].join("\n");
}

export function floatingModelUsageMoneyText(value: number): string {
  if (value >= 100) return `$${value.toFixed(0)}`;
  if (value >= 10) return `$${value.toFixed(1)}`;
  return `$${value.toFixed(2)}`;
}

function detailedShareText(share: number): string {
  const percent = Math.max(0, share) * 100;
  if (percent > 0 && percent < 0.1) return "<0.1%";
  if (percent < 10 && Math.round(percent) !== percent) return `${percent.toFixed(1)}%`;
  return `${Math.round(percent)}%`;
}

function finiteNonnegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
}

function dashboardModelUsagePlaceholder(key: string): FloatingModelUsageItem {
  return {
    key,
    label: modelUsageLabel(key),
    tokens: 0,
    share: 0,
    costUSD: 0,
    usesIndependentQuota: false,
    referenceCostUSD: null,
    color: modelUsageColor(key),
  };
}
