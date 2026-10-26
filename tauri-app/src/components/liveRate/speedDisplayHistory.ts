import type { ModelRateContribution } from "../../types/live";
import type { ActivityRateHistoryPoint } from "./activityRatePresentation";

/** Bounded local history for this algorithm only; long gaps are never backfilled. */
export class SpeedDisplayHistory {
  private buckets = new Map<number, { seconds: number; tokens: Map<string, number> }>();
  private previousAt: number | null = null;
  private previousRates: ModelRateContribution[] = [];
  record(now: number, rates: ModelRateContribution[]) {
    if (!Number.isFinite(now)) return;
    if (this.previousAt !== null && now < this.previousAt) { this.buckets.clear(); this.previousAt = null; }
    if (this.previousAt !== null) {
      let cursor = this.previousAt;
      const end = Math.min(now, cursor + 2);
      while (cursor < end) {
        const key = Math.floor(cursor / 5) * 5, stop = Math.min(end, key + 5), seconds = stop - cursor;
        const bucket = this.buckets.get(key) ?? { seconds: 0, tokens: new Map<string, number>() };
        bucket.seconds += seconds;
        for (const rate of this.previousRates) bucket.tokens.set(rate.model, (bucket.tokens.get(rate.model) ?? 0) + rate.tokensPerSecond * seconds);
        this.buckets.set(key, bucket); cursor = stop;
      }
    }
    this.previousAt = now;
    this.previousRates = rates.filter(r => Number.isFinite(r.tokensPerSecond) && r.tokensPerSecond > 0);
    for (const key of this.buckets.keys()) if (key < now - 1800) this.buckets.delete(key);
  }
  points(now = Date.now() / 1000): ActivityRateHistoryPoint[] {
    return [...this.buckets].filter(([start, bucket]) => start + 5 <= now && start >= now - 1800 && bucket.seconds > 0)
      .sort(([a], [b]) => a - b).map(([start, bucket]) => ({ start,
        modelRates: [...bucket.tokens].map(([model, tokens]) => ({ model, tokensPerSecond: tokens / bucket.seconds })) }));
  }
}
export const localAgentSpeedHistory = new SpeedDisplayHistory();
