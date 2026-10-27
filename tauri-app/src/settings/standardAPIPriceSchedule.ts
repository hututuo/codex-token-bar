import bundled from "../../../Vendor/AgentSpeed/spec/assets/prices.json" with { type: "json" };
import history from "../../../Sources/CodexTokenBar/Resources/standard-api-price-history.json" with { type: "json" };

/** Input, cached-input, and output rates for one million standard API tokens.
 * Local Codex usage does not expose cache writes separately. This module keeps
 * historical prices independent from quotaPriceModel.ts. */
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

const newestHistory = [...history.rows].reverse();
const currentModels = new Map(bundled.models.map(model => [model.id, model]));

export const STANDARD_API_PRICE_SCHEDULE_REVISION = "standard-api-dated-v3";

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
    case "gpt-6.1-sol":
    case "gpt6.1-sol":
    case "gpt61-sol":
    case "gpt61sol":
      return "gpt-6.1-sol";
    case "gpt-6-sol":
    case "gpt6-sol":
    case "gpt6sol":
      return "gpt-6-sol";
    case "gpt-6-luna":
    case "gpt6-luna":
    case "gpt6luna":
      return "gpt-6-luna";
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
    case "gpt54legacy":
      return "gpt-5.4";
    case "gpt-5.4-mini":
    case "gpt54mini":
    case "gpt54minilegacy":
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

  const row = newestHistory.find(row => row.modelKey === modelKey && (row.fromUnix ?? -Infinity) <= eventUnix);
  return row ? fixedQuote(modelKey, { ...row.rates }, row.revision) : null;
}

/** Current rates use the same pinned asset as the multi-client price book. */
export function currentStandardAPIPriceQuote(rawModel: string | null | undefined): StandardAPIPriceQuote | null {
  const modelKey = canonicalStandardAPIModelKey(rawModel);
  if (!modelKey) return null;
  const model = currentModels.get(modelKey);
  const revision = newestHistory.find(row => row.modelKey === modelKey)?.revision;
  if (!model || !('prices' in model) || !model.prices || !revision) return null;
  const prices = model.prices;
  return fixedQuote(modelKey, {
    inputUSDPerMillion: prices.input,
    cachedInputUSDPerMillion: 'cachedInput' in prices ? prices.cachedInput! : prices.input,
    outputUSDPerMillion: prices.output,
  }, revision);
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
