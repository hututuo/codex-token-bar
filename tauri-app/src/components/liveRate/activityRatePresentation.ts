import type { ModelRateContribution } from "../../types/live";
import { currentStandardAPIPriceQuote } from "../../settings/standardAPIPriceSchedule";
export type ActivityRateUnit = "tok/s" | "CN 元/s";
export const ACTIVITY_RATE_UNIT_KEY = "activityRateDisplayUnit";
export const ACTIVITY_RATE_FX_KEY = "activityRateCNYPerUSD";
export const DEFAULT_ACTIVITY_RATE_FX = 7.2;
export interface ActivityRateHistoryPoint { start: number; modelRates: ModelRateContribution[] }
export const safeActivityRateFX = (value: number) => Number.isFinite(value) && value >= .1 && value <= 100 ? value : DEFAULT_ACTIVITY_RATE_FX;
export function activityRateValue(total: number, rates: ModelRateContribution[] | undefined, unit: ActivityRateUnit, fx: number): number | null {
  if (!Number.isFinite(total) || total < 0) return null;
  if (unit === "tok/s" || total === 0) return total;
  let represented = 0, usd = 0;
  for (const rate of rates ?? []) {
    if (!Number.isFinite(rate.tokensPerSecond) || rate.tokensPerSecond <= 0) continue;
    const quote = currentStandardAPIPriceQuote(rate.model);
    if (!quote) return null;
    represented += rate.tokensPerSecond;
    usd += rate.tokensPerSecond * quote.rates.outputUSDPerMillion / 1e6;
  }
  return represented >= total - Math.max(.05, total * .001) ? usd * safeActivityRateFX(fx) : null;
}
export function activityRateText(value: number | null, unit: ActivityRateUnit): string {
  if (value === null || !Number.isFinite(value)) return "—";
  if (unit === "CN 元/s" && value > 0 && value < .0001) return "<0.0001";
  return value.toFixed(unit === "tok/s" ? 1 : 4);
}
