import type { ModelRateContribution } from "../../types/live";
import { modelUsageColor, modelUsageKey } from "../modelUsagePresentation.ts";

/** Current activity-curve contributions, not historical measured TPS. */
export function modelRateSlices(rates?: ModelRateContribution[]) {
  const grouped = new Map<string, number>();
  for (const rate of rates ?? []) {
    if (!Number.isFinite(rate.tokensPerSecond) || rate.tokensPerSecond <= 0) continue;
    const model = modelUsageKey(rate.model);
    grouped.set(model, (grouped.get(model) ?? 0) + rate.tokensPerSecond);
  }
  const total = [...grouped.values()].reduce((a,b) => a+b, 0);
  if (!Number.isFinite(total) || total <= 0) return [];
  return [...grouped].sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([model,tokensPerSecond]) => ({ model, tokensPerSecond, share: tokensPerSecond / total, color: modelUsageColor(model) }));
}
export function modelRateGradient(rates?: ModelRateContribution[], direction = "90deg") {
  const slices = modelRateSlices(rates);
  if (!slices.length) return modelUsageColor("unknown");
  let edge = 0;
  const stops = slices.flatMap(slice => {
    const start = edge; edge += slice.share;
    return [`${slice.color} ${start*100}%`, `${slice.color} ${Math.min(1,edge)*100}%`];
  });
  return `linear-gradient(${direction}, ${stops.join(", ")})`;
}
