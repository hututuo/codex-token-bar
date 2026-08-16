export type OfficialAPIPriceModel =
  | "gpt56Sol"
  | "gpt56Terra"
  | "gpt56Luna"
  | "gpt53Codex"
  | "gpt52Codex"
  | "gpt54Legacy"
  | "gpt54MiniLegacy";

export type QuotaPriceBasis = "current" | "radar20260730";

/**
 * A versioned model-routing rule. Raw usage rows keep their original model
 * alias; this table only decides which billable model that alias represents
 * at a given UTC instant. Add future routing changes as new dated rules
 * instead of rewriting old events or migrating the exact index.
 */
export interface ModelPricingRule {
  alias: string;
  /** Unix seconds, always interpreted as UTC. */
  effectiveFrom: number;
  targetModel: OfficialAPIPriceModel;
  revision: string;
}

const CODEX_AUTO_REVIEW_LUNA_EFFECTIVE_FROM = Date.UTC(2026, 6, 30) / 1000;

export const CODEX_AUTO_REVIEW_PRICING_RULES: ReadonlyArray<ModelPricingRule> = [
  {
    alias: "codex-auto-review",
    effectiveFrom: Number.NEGATIVE_INFINITY,
    targetModel: "gpt54Legacy",
    revision: "codex-auto-review-pre-luna",
  },
  {
    alias: "codex-auto-review",
    effectiveFrom: CODEX_AUTO_REVIEW_LUNA_EFFECTIVE_FROM,
    targetModel: "gpt56Luna",
    revision: "codex-auto-review-luna-20260730",
  },
];

export interface APIPriceRates {
  inputUSDPerMillion: number;
  cachedInputUSDPerMillion: number;
  outputUSDPerMillion: number;
}

/**
 * Spark has a separate Codex quota and no final official Spark-specific rate
 * card. Keep this explicitly provisional reference price separate from the
 * official API price table and from quota-drop attribution totals.
 */
export const SPARK_REFERENCE_PRICE_REVISION = "gpt-5.3-codex-spark-reference-api-20260815";
export const SPARK_REFERENCE_API_PRICES: APIPriceRates = Object.freeze({
  inputUSDPerMillion: 1.75,
  cachedInputUSDPerMillion: 0.175,
  outputUSDPerMillion: 14,
});

export interface ModelTokenCostRow {
  model: string | null;
  /** Event/bucket start in Unix seconds. Absent for legacy aggregate rows. */
  eventStartUnix?: number;
  breakdown: {
    inputTokens: number;
    cachedInputTokens: number;
    outputTokens: number;
    calls: number;
  };
}

export interface ModelAwareAPICostEstimate {
  costUSD: number;
  detectedModels: OfficialAPIPriceModel[];
  fallbackCalls: number;
  /** Models on an independent quota; retained in token/model stats but never priced. */
  excludedModels: string[];
  excludedCalls: number;
}

export const QUOTA_PRICE_MODEL_STORAGE_KEY = "recentChartQuotaEstimateModel";
export const QUOTA_PRICE_MODEL_EVENT = "codex-token-bar:quota-price-model";

export const QUOTA_PRICE_MODEL_OPTIONS: ReadonlyArray<{
  value: OfficialAPIPriceModel;
  label: string;
}> = [
  { value: "gpt56Sol", label: "GPT-5.6 Sol" },
  { value: "gpt56Terra", label: "GPT-5.6 Terra" },
  { value: "gpt56Luna", label: "GPT-5.6 Luna" },
];

// Standard short-context prices published by OpenAI. Long-context, cache-write,
// priority/service-tier and regional multipliers remain outside this estimate.
// https://developers.openai.com/api/docs/models/compare
const CURRENT_API_PRICES: Record<OfficialAPIPriceModel, APIPriceRates> = {
  gpt56Sol: { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 },
  gpt56Terra: { inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.2, outputUSDPerMillion: 12 },
  gpt56Luna: { inputUSDPerMillion: 0.2, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.2 },
  gpt53Codex: { inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14 },
  gpt52Codex: { inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14 },
  gpt54Legacy: { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 },
  gpt54MiniLegacy: { inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.5 },
};

// Codex Radar's public 2026-07-30 quota basis uses the then-published model
// price card. Keep this separate from current OpenAI prices so both sides of
// the attribution division use one vintage. Source: https://codexradar.com/
const RADAR_2026_07_30_PRICES: Record<OfficialAPIPriceModel, APIPriceRates> = {
  gpt56Sol: { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 },
  gpt56Terra: { inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.2, outputUSDPerMillion: 12 },
  gpt56Luna: { inputUSDPerMillion: 0.2, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.2 },
  gpt53Codex: { inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14 },
  gpt52Codex: { inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14 },
  gpt54Legacy: { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 },
  gpt54MiniLegacy: { inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.5 },
};

const LEGACY_PRICE_MODEL_MIGRATIONS: Record<string, OfficialAPIPriceModel> = {
  gpt55: "gpt56Sol",
  gpt54: "gpt56Terra",
  gpt54Mini: "gpt56Luna",
};

export function normalizeOfficialAPIPriceModel(value: unknown): OfficialAPIPriceModel | null {
  if (value === "gpt56Sol"
    || value === "gpt56Terra"
    || value === "gpt56Luna"
    || value === "gpt53Codex"
    || value === "gpt52Codex"
    || value === "gpt54Legacy"
    || value === "gpt54MiniLegacy") {
    return value;
  }
  return typeof value === "string" ? LEGACY_PRICE_MODEL_MIGRATIONS[value] ?? null : null;
}

export function isOfficialAPIPriceModel(value: unknown): value is OfficialAPIPriceModel {
  return value === "gpt56Sol"
    || value === "gpt56Terra"
    || value === "gpt56Luna"
    || value === "gpt53Codex"
    || value === "gpt52Codex"
    || value === "gpt54Legacy"
    || value === "gpt54MiniLegacy";
}

export function readStoredQuotaPriceModel(storage?: Pick<Storage, "getItem" | "setItem"> | null): OfficialAPIPriceModel {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target) return "gpt56Sol";
  const stored = target.getItem(QUOTA_PRICE_MODEL_STORAGE_KEY);
  const normalized = normalizeOfficialAPIPriceModel(stored) ?? "gpt56Sol";
  if (stored !== null && stored !== normalized) {
    target.setItem(QUOTA_PRICE_MODEL_STORAGE_KEY, normalized);
  }
  return normalized;
}

export function writeStoredQuotaPriceModel(model: OfficialAPIPriceModel): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(QUOTA_PRICE_MODEL_STORAGE_KEY, model);
  window.dispatchEvent(new CustomEvent(QUOTA_PRICE_MODEL_EVENT, { detail: model }));
}

export function officialAPIPrices(
  priceModel: OfficialAPIPriceModel,
  basis: QuotaPriceBasis = "current",
): APIPriceRates {
  const normalized = normalizeOfficialAPIPriceModel(priceModel) ?? "gpt56Sol";
  return basis === "radar20260730"
    ? RADAR_2026_07_30_PRICES[normalized]
    : CURRENT_API_PRICES[normalized];
}

export function officialAPICostUSD(
  inputTokens: number,
  cachedInputTokens: number,
  outputTokens: number,
  priceModel: OfficialAPIPriceModel,
  basis: QuotaPriceBasis = "current",
): number {
  const prices = officialAPIPrices(priceModel, basis);
  const input = finiteNonnegative(inputTokens);
  const cachedInput = Math.min(finiteNonnegative(cachedInputTokens), input);
  const uncachedInput = Math.max(0, input - cachedInput);
  return (
    uncachedInput * prices.inputUSDPerMillion
    + cachedInput * prices.cachedInputUSDPerMillion
    + finiteNonnegative(outputTokens) * prices.outputUSDPerMillion
  ) / 1_000_000;
}

export function independentQuotaReferenceCostUSD(
  model: string | null | undefined,
  inputTokens: number,
  cachedInputTokens: number,
  outputTokens: number,
): number | null {
  if (independentQuotaModelName(model) === null) return null;
  const input = finiteNonnegative(inputTokens);
  const cachedInput = Math.min(finiteNonnegative(cachedInputTokens), input);
  const uncachedInput = Math.max(0, input - cachedInput);
  return (
    uncachedInput * SPARK_REFERENCE_API_PRICES.inputUSDPerMillion
    + cachedInput * SPARK_REFERENCE_API_PRICES.cachedInputUSDPerMillion
    + finiteNonnegative(outputTokens) * SPARK_REFERENCE_API_PRICES.outputUSDPerMillion
  ) / 1_000_000;
}

export function detectedOfficialAPIPriceModel(
  value: string | null | undefined,
  eventDate?: Date | number | string | null,
): OfficialAPIPriceModel | null {
  const key = value?.trim().toLowerCase().replaceAll("_", "-");
  const autoReviewModel = effectiveModelForAlias(value, eventDate);
  if (autoReviewModel) return autoReviewModel;
  switch (key) {
    case "gpt-5.6":
    case "gpt5.6":
    case "gpt56":
    case "gpt-5.6-sol":
    case "gpt5.6-sol":
    case "gpt56-sol":
    case "gpt56sol":
    case "gpt-5.5":
    case "gpt55":
      return "gpt56Sol";
    case "gpt-5.6-terra":
    case "gpt5.6-terra":
    case "gpt56-terra":
    case "gpt56terra":
      return "gpt56Terra";
    case "gpt-5.6-luna":
    case "gpt5.6-luna":
    case "gpt56-luna":
    case "gpt56luna":
      return "gpt56Luna";
    case "gpt-5.3-codex":
    case "gpt5.3-codex":
    case "gpt53-codex":
    case "gpt53codex":
      return "gpt53Codex";
    case "gpt-5.2-codex":
    case "gpt5.2-codex":
    case "gpt52-codex":
    case "gpt52codex":
      return "gpt52Codex";
    case "gpt-5.4":
    case "gpt54":
      return "gpt54Legacy";
    case "gpt-5.4-mini":
    case "gpt54mini":
      return "gpt54MiniLegacy";
    default:
      return null;
  }
}

export function modelAwareAPICostUSD(
  rows: ModelTokenCostRow[] | null | undefined,
  fallback: ModelTokenCostRow["breakdown"],
  fallbackModel: OfficialAPIPriceModel,
  basis: QuotaPriceBasis = "current",
): ModelAwareAPICostEstimate {
  if (!rows || rows.length === 0) {
    return {
      costUSD: officialAPICostUSD(fallback.inputTokens, fallback.cachedInputTokens, fallback.outputTokens, fallbackModel, basis),
      detectedModels: [],
      fallbackCalls: fallback.calls,
      excludedModels: [],
      excludedCalls: 0,
    };
  }
  const covered = rows.reduce((total, row) => ({
    inputTokens: total.inputTokens + finiteNonnegative(row.breakdown.inputTokens),
    cachedInputTokens: total.cachedInputTokens + finiteNonnegative(row.breakdown.cachedInputTokens),
    outputTokens: total.outputTokens + finiteNonnegative(row.breakdown.outputTokens),
    calls: total.calls + finiteNonnegative(row.breakdown.calls),
  }), { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 });
  const excludedModels: string[] = [];
  let excludedCalls = 0;
  const excludedBreakdown = rows.reduce((total, row) => {
    const excluded = independentQuotaModelName(row.model);
    if (!excluded) return total;
    if (!excludedModels.includes(excluded)) excludedModels.push(excluded);
    excludedCalls += finiteNonnegative(row.breakdown.calls);
    return {
      inputTokens: total.inputTokens + finiteNonnegative(row.breakdown.inputTokens),
      cachedInputTokens: total.cachedInputTokens + finiteNonnegative(row.breakdown.cachedInputTokens),
      outputTokens: total.outputTokens + finiteNonnegative(row.breakdown.outputTokens),
      calls: total.calls + finiteNonnegative(row.breakdown.calls),
    };
  }, { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 });
  const expected = {
    inputTokens: finiteNonnegative(fallback.inputTokens),
    cachedInputTokens: finiteNonnegative(fallback.cachedInputTokens),
    outputTokens: finiteNonnegative(fallback.outputTokens),
    calls: finiteNonnegative(fallback.calls),
  };
  if (covered.inputTokens !== expected.inputTokens
    || covered.cachedInputTokens !== expected.cachedInputTokens
    || covered.outputTokens !== expected.outputTokens
    || covered.calls !== expected.calls) {
    return {
      costUSD: officialAPICostUSD(
        Math.max(expected.inputTokens - excludedBreakdown.inputTokens, 0),
        Math.max(expected.cachedInputTokens - excludedBreakdown.cachedInputTokens, 0),
        Math.max(expected.outputTokens - excludedBreakdown.outputTokens, 0),
        fallbackModel,
        basis,
      ),
      detectedModels: [],
      fallbackCalls: Math.max(expected.calls - excludedBreakdown.calls, 0),
      excludedModels,
      excludedCalls,
    };
  }
  const grouped = new Map<OfficialAPIPriceModel, ModelTokenCostRow["breakdown"]>();
  const unknown = { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 };
  for (const row of rows) {
    const excluded = independentQuotaModelName(row.model);
    if (excluded) {
      continue;
    }
    const detected = detectedOfficialAPIPriceModel(row.model, row.eventStartUnix);
    const target = detected
      ? grouped.get(detected) ?? { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 }
      : unknown;
    target.inputTokens += row.breakdown.inputTokens;
    target.cachedInputTokens += row.breakdown.cachedInputTokens;
    target.outputTokens += row.breakdown.outputTokens;
    target.calls += row.breakdown.calls;
    if (detected) grouped.set(detected, target);
  }
  let costUSD = officialAPICostUSD(unknown.inputTokens, unknown.cachedInputTokens, unknown.outputTokens, fallbackModel, basis);
  for (const [model, breakdown] of grouped) {
    costUSD += officialAPICostUSD(breakdown.inputTokens, breakdown.cachedInputTokens, breakdown.outputTokens, model, basis);
  }
  return {
    costUSD,
    detectedModels: ([
      "gpt56Sol",
      "gpt56Terra",
      "gpt56Luna",
      "gpt53Codex",
      "gpt52Codex",
      "gpt54Legacy",
      "gpt54MiniLegacy",
    ] satisfies OfficialAPIPriceModel[]).filter((model) => grouped.has(model)),
    fallbackCalls: unknown.calls,
    excludedModels,
    excludedCalls,
  };
}

export function priceModelTitle(model: OfficialAPIPriceModel): string {
  switch (normalizeOfficialAPIPriceModel(model) ?? "gpt56Sol") {
    case "gpt56Sol": return "GPT-5.6 Sol";
    case "gpt56Terra": return "GPT-5.6 Terra";
    case "gpt56Luna": return "GPT-5.6 Luna";
    case "gpt53Codex": return "GPT-5.3 Codex";
    case "gpt52Codex": return "GPT-5.2 Codex";
    case "gpt54Legacy": return "GPT-5.4";
    case "gpt54MiniLegacy": return "GPT-5.4 Mini";
  }
}

/** Canonical model names on the separate Spark quota. */
export function independentQuotaModelName(value: string | null | undefined): string | null {
  const key = canonicalModelKey(value);
  return key === "gpt53codexspark" ? "gpt-5.3-codex-spark" : null;
}

function canonicalModelKey(value: string | null | undefined): string {
  return (value ?? "")
    .trim()
    .toLowerCase()
    .replaceAll("_", "-")
    .replace(/[^a-z0-9]+/g, "");
}

/** Resolve the dated rule for an alias, using the current rule for legacy rows. */
export function effectiveModelForAlias(
  value: string | null | undefined,
  eventDate?: Date | number | string | null,
): OfficialAPIPriceModel | null {
  const alias = canonicalModelKey(value);
  if (!alias) return null;
  const candidates = CODEX_AUTO_REVIEW_PRICING_RULES.filter(
    (rule) => canonicalModelKey(rule.alias) === alias,
  );
  if (candidates.length === 0) return null;

  const eventUnix = eventTimestampUnix(eventDate);
  const effectiveAt = eventUnix ?? Number.POSITIVE_INFINITY;
  return candidates
    .filter((rule) => rule.effectiveFrom <= effectiveAt)
    .sort((left, right) => right.effectiveFrom - left.effectiveFrom)[0]?.targetModel ?? null;
}

export function isCodexAutoReviewAlias(value: string | null | undefined): boolean {
  const alias = canonicalModelKey(value);
  return alias.length > 0 && CODEX_AUTO_REVIEW_PRICING_RULES.some(
    (rule) => canonicalModelKey(rule.alias) === alias,
  );
}

function eventTimestampUnix(value: Date | number | string | null | undefined): number | null {
  if (value instanceof Date) {
    const milliseconds = value.getTime();
    return Number.isFinite(milliseconds) ? milliseconds / 1000 : null;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    // Accept both Unix seconds and the millisecond form used by Date.now().
    return Math.abs(value) >= 1e12 ? value / 1000 : value;
  }
  if (typeof value === "string" && value.trim().length > 0) {
    const milliseconds = Date.parse(value);
    return Number.isFinite(milliseconds) ? milliseconds / 1000 : null;
  }
  return null;
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}
