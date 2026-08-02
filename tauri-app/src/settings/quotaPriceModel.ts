export type OfficialAPIPriceModel =
  | "gpt56Sol"
  | "gpt56Terra"
  | "gpt56Luna"
  | "gpt54Legacy"
  | "gpt54MiniLegacy";

export type QuotaPriceBasis = "current" | "radar20260730";

export interface APIPriceRates {
  inputUSDPerMillion: number;
  cachedInputUSDPerMillion: number;
  outputUSDPerMillion: number;
}

export interface ModelTokenCostRow {
  model: string | null;
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

const CURRENT_API_PRICES: Record<OfficialAPIPriceModel, APIPriceRates> = {
  gpt56Sol: { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 },
  gpt56Terra: { inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.2, outputUSDPerMillion: 12 },
  gpt56Luna: { inputUSDPerMillion: 0.2, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.2 },
  gpt54Legacy: { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 },
  gpt54MiniLegacy: { inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.5 },
};

// Codex Radar's public 2026-07-30 quota basis uses the then-published model
// price card. Keep this separate from current OpenAI prices so both sides of
// the attribution division use one vintage. Source: https://codexradar.com/
const RADAR_2026_07_30_PRICES: Record<OfficialAPIPriceModel, APIPriceRates> = {
  gpt56Sol: { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 },
  gpt56Terra: { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 },
  gpt56Luna: { inputUSDPerMillion: 1, cachedInputUSDPerMillion: 0.1, outputUSDPerMillion: 6 },
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

export function detectedOfficialAPIPriceModel(value: string | null | undefined): OfficialAPIPriceModel | null {
  const key = value?.trim().toLowerCase().replaceAll("_", "-");
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
    };
  }
  const covered = rows.reduce((total, row) => ({
    inputTokens: total.inputTokens + finiteNonnegative(row.breakdown.inputTokens),
    cachedInputTokens: total.cachedInputTokens + finiteNonnegative(row.breakdown.cachedInputTokens),
    outputTokens: total.outputTokens + finiteNonnegative(row.breakdown.outputTokens),
    calls: total.calls + finiteNonnegative(row.breakdown.calls),
  }), { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 });
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
        expected.inputTokens,
        expected.cachedInputTokens,
        expected.outputTokens,
        fallbackModel,
        basis,
      ),
      detectedModels: [],
      fallbackCalls: expected.calls,
    };
  }
  const grouped = new Map<OfficialAPIPriceModel, ModelTokenCostRow["breakdown"]>();
  const unknown = { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, calls: 0 };
  for (const row of rows) {
    const detected = detectedOfficialAPIPriceModel(row.model);
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
      "gpt54Legacy",
      "gpt54MiniLegacy",
    ] satisfies OfficialAPIPriceModel[]).filter((model) => grouped.has(model)),
    fallbackCalls: unknown.calls,
  };
}

export function priceModelTitle(model: OfficialAPIPriceModel): string {
  switch (normalizeOfficialAPIPriceModel(model) ?? "gpt56Sol") {
    case "gpt56Sol": return "GPT-5.6 Sol";
    case "gpt56Terra": return "GPT-5.6 Terra";
    case "gpt56Luna": return "GPT-5.6 Luna";
    case "gpt54Legacy": return "GPT-5.4";
    case "gpt54MiniLegacy": return "GPT-5.4 Mini";
  }
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}
