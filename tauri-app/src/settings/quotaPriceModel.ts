export type OfficialAPIPriceModel = "gpt56Sol" | "gpt56Terra" | "gpt56Luna";

export type QuotaPriceBasis = "current" | "radar20260730";

export interface APIPriceRates {
  inputUSDPerMillion: number;
  cachedInputUSDPerMillion: number;
  outputUSDPerMillion: number;
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
};

// The 2026-07-30 Radar quota total was calibrated with this then-published price card.
// Attribution must use the same basis on both sides of the division.
const RADAR_2026_07_30_PRICES: Record<OfficialAPIPriceModel, APIPriceRates> = {
  gpt56Sol: { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 },
  gpt56Terra: { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 },
  gpt56Luna: { inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.5 },
};

const LEGACY_PRICE_MODEL_MIGRATIONS: Record<string, OfficialAPIPriceModel> = {
  gpt55: "gpt56Sol",
  gpt54: "gpt56Terra",
  gpt54Mini: "gpt56Luna",
};

export function normalizeOfficialAPIPriceModel(value: unknown): OfficialAPIPriceModel | null {
  if (value === "gpt56Sol" || value === "gpt56Terra" || value === "gpt56Luna") {
    return value;
  }
  return typeof value === "string" ? LEGACY_PRICE_MODEL_MIGRATIONS[value] ?? null : null;
}

export function isOfficialAPIPriceModel(value: unknown): value is OfficialAPIPriceModel {
  return value === "gpt56Sol" || value === "gpt56Terra" || value === "gpt56Luna";
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

export function priceModelTitle(model: OfficialAPIPriceModel): string {
  switch (normalizeOfficialAPIPriceModel(model) ?? "gpt56Sol") {
    case "gpt56Sol": return "GPT-5.6 Sol";
    case "gpt56Terra": return "GPT-5.6 Terra";
    case "gpt56Luna": return "GPT-5.6 Luna";
  }
}

function finiteNonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}
