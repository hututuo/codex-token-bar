import {
  modelUsageColor,
  modelUsageKey,
  modelUsageLabel,
  type ModelUsageRowLike,
} from "../components/modelUsagePresentation.ts";
import {
  detectedOfficialAPIPriceModel,
  independentQuotaReferenceCostUSD,
  independentQuotaModelName,
  officialAPICostUSD,
  type OfficialAPIPriceModel,
} from "../settings/quotaPriceModel.ts";
import { formatTokens } from "../utils/format.ts";

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
export const DASHBOARD_PRIMARY_MODEL_KEYS = [
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
] as const;

interface CombinedModelUsage {
  model: string | null;
  eventStartUnix?: number;
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
  "gpt-5.4",
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
    const key = modelUsageKey(row.model, row.eventStartUnix);
    const current = grouped.get(key) ?? {
      model: row.model,
      eventStartUnix: row.eventStartUnix,
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
    const priceModel = detectedOfficialAPIPriceModel(row.model, row.eventStartUnix) ?? fallbackModel;
    const costUSD = usesIndependentQuota
      ? null
      : officialAPICostUSD(
        row.inputTokens,
        row.cachedInputTokens,
        row.outputTokens,
        priceModel,
      );
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
  return floatingModelUsageMoneyText(item.costUSD ?? 0);
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
    const cost = item.usesIndependentQuota
      ? `${item.referenceCostUSD === null ? "—" : floatingModelUsageMoneyText(item.referenceCostUSD)}（不计入总计）`
      : floatingModelUsageMoneyText(item.costUSD ?? 0);
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
