/** Rates for one million standard API tokens, kept local to this module so
 * the historical schedule has no runtime dependency on quotaPriceModel.ts. */
export interface StandardAPIPriceRates {
  inputUSDPerMillion: number;
  cachedInputUSDPerMillion: number;
  outputUSDPerMillion: number;
}

export interface StandardAPIPriceQuote {
  /** Canonical key retained by this table, not a legacy storage enum. */
  modelKey: string;
  rates: StandardAPIPriceRates;
  revision: string;
}

export type StandardAPIEventTime = Date | number | string;

const SOL_CUTOVER_UNIX = Date.UTC(2026, 7, 21) / 1000;
const TERRA_AND_LUNA_CUTOVER_UNIX = Date.UTC(2026, 6, 30) / 1000;

/**
 * Normalize aliases while keeping the canonical model spelling independent of
 * the legacy quota price-model enum. Auto-review and Spark are intentionally
 * not aliases in this standard API table.
 */
export function canonicalStandardAPIModelKey(value: string | null | undefined): string | null {
  if (typeof value !== "string") return null;
  const key = value.trim().toLowerCase().replaceAll("_", "-").replaceAll(" ", "-").replace(/-+/g, "-");
  switch (key) {
    case "gpt-6-astra":
    case "gpt6-astra":
    case "gpt6astra":
      return "gpt-6-astra";
    case "gpt-5.6":
    case "gpt5.6":
    case "gpt56":
    case "gpt-5.6-sol":
    case "gpt5.6-sol":
    case "gpt56-sol":
    case "gpt56sol":
      return "gpt-5.6-sol";
    case "gpt-5.5":
    case "gpt5.5":
    case "gpt55":
      return "gpt-5.5";
    case "gpt-5.6-terra":
    case "gpt5.6-terra":
    case "gpt56-terra":
    case "gpt56terra":
      return "gpt-5.6-terra";
    case "gpt-5.6-luna":
    case "gpt5.6-luna":
    case "gpt56-luna":
    case "gpt56luna":
      return "gpt-5.6-luna";
    case "gpt-5.3-codex":
    case "gpt5.3-codex":
    case "gpt53-codex":
    case "gpt53codex":
      return "gpt-5.3-codex";
    case "gpt-5.2-codex":
    case "gpt5.2-codex":
    case "gpt52-codex":
    case "gpt52codex":
      return "gpt-5.2-codex";
    case "gpt-5.4":
    case "gpt54":
      return "gpt-5.4";
    case "gpt-5.4-mini":
    case "gpt54mini":
      return "gpt-5.4-mini";
    default:
      return null;
  }
}

/**
 * Look up a historical standard API card at an explicit event time.
 * Invalid or missing event times return null; callers must choose the current
 * query explicitly when a current estimate is wanted.
 */
export function standardAPIPriceQuote(
  rawModel: string | null | undefined,
  eventTime: StandardAPIEventTime | null | undefined,
): StandardAPIPriceQuote | null {
  const modelKey = canonicalStandardAPIModelKey(rawModel);
  const eventUnix = standardAPIEventTimeUnix(eventTime);
  if (!modelKey || eventUnix === null) return null;

  switch (modelKey) {
    case "gpt-6-astra":
      return fixedQuote(modelKey, { inputUSDPerMillion: 10, cachedInputUSDPerMillion: 1, outputUSDPerMillion: 50 }, "standard-api-gpt-6-astra");
    case "gpt-5.5":
      return fixedQuote(modelKey, { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 }, "standard-api-gpt-5.5");
    case "gpt-5.6-sol":
      return eventUnix < SOL_CUTOVER_UNIX
        ? fixedQuote(modelKey, { inputUSDPerMillion: 5, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 30 }, "standard-api-gpt-5.6-sol-before-2026-08-21")
        : fixedQuote(modelKey, { inputUSDPerMillion: 4, cachedInputUSDPerMillion: 0.4, outputUSDPerMillion: 20 }, "standard-api-gpt-5.6-sol-from-2026-08-21");
    case "gpt-5.6-terra":
      return eventUnix < TERRA_AND_LUNA_CUTOVER_UNIX
        ? fixedQuote(modelKey, { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 }, "standard-api-gpt-5.6-terra-before-2026-07-30")
        : fixedQuote(modelKey, { inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.2, outputUSDPerMillion: 12 }, "standard-api-gpt-5.6-terra-from-2026-07-30");
    case "gpt-5.6-luna":
      return eventUnix < TERRA_AND_LUNA_CUTOVER_UNIX
        ? fixedQuote(modelKey, { inputUSDPerMillion: 1, cachedInputUSDPerMillion: 0.1, outputUSDPerMillion: 6 }, "standard-api-gpt-5.6-luna-before-2026-07-30")
        : fixedQuote(modelKey, { inputUSDPerMillion: 0.2, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.2 }, "standard-api-gpt-5.6-luna-from-2026-07-30");
    case "gpt-5.3-codex":
    case "gpt-5.2-codex":
      return fixedQuote(modelKey, { inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14 }, `standard-api-${modelKey}`);
    case "gpt-5.4":
      return fixedQuote(modelKey, { inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15 }, "standard-api-gpt-5.4");
    case "gpt-5.4-mini":
      return fixedQuote(modelKey, { inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.5 }, "standard-api-gpt-5.4-mini");
    default:
      return null;
  }
}

/** Explicit current-price query, independent from historical event lookup. */
export function currentStandardAPIPriceQuote(rawModel: string | null | undefined): StandardAPIPriceQuote | null {
  const modelKey = canonicalStandardAPIModelKey(rawModel);
  if (!modelKey) return null;
  switch (modelKey) {
    case "gpt-5.6-sol":
      return fixedQuote(modelKey, { inputUSDPerMillion: 4, cachedInputUSDPerMillion: 0.4, outputUSDPerMillion: 20 }, "standard-api-gpt-5.6-sol-from-2026-08-21");
    case "gpt-5.6-terra":
      return fixedQuote(modelKey, { inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.2, outputUSDPerMillion: 12 }, "standard-api-gpt-5.6-terra-from-2026-07-30");
    case "gpt-5.6-luna":
      return fixedQuote(modelKey, { inputUSDPerMillion: 0.2, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.2 }, "standard-api-gpt-5.6-luna-from-2026-07-30");
    default:
      // Fixed-price cards still require an explicit date in the historical API.
      return standardAPIPriceQuote(modelKey, SOL_CUTOVER_UNIX);
  }
}

function fixedQuote(modelKey: string, rates: StandardAPIPriceRates, revision: string): StandardAPIPriceQuote {
  return { modelKey, rates, revision };
}

function standardAPIEventTimeUnix(value: StandardAPIEventTime | null | undefined): number | null {
  if (value instanceof Date) {
    const milliseconds = value.getTime();
    return Number.isFinite(milliseconds) ? milliseconds / 1000 : null;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.abs(value) >= 1e12 ? value / 1000 : value;
  }
  if (typeof value === "string" && value.trim().length > 0) {
    const milliseconds = Date.parse(value);
    return Number.isFinite(milliseconds) ? milliseconds / 1000 : null;
  }
  return null;
}
