import type { ModelRateContribution } from "../../types/live";
import { floatingModelUsageKey, modelUsageColor, modelUsageKey, modelUsageLabel } from "../modelUsagePresentation.ts";
import type { SpeedColorGrouping } from "./speedDisplay.ts";

export interface ModelRateSource {
  client: string; sourceKey: string; observedAt: number; available: boolean;
  rates: readonly ModelRateContribution[]; total?: number;
}
export interface LiveModelRateRow {
  id: string; client: string; model: string; rawModels: string[]; colorKey: string;
  label: string; clientLabel: string; tokensPerSecond: number; share: number; barFraction: number;
}
export interface LiveModelRateSnapshot {
  sources: ModelRateSource[]; sourceKey: string; mode: "bar" | "agentSpeed"; grouping: SpeedColorGrouping;
  enabled: boolean; available: boolean; total: number; rows: LiveModelRateRow[];
  modelRates: ModelRateContribution[]; colorRates: ModelRateContribution[]; status: string;
}

/** Reader totals are authoritative; missing attribution remains unknown. */
export function normalizedModelRates(rates: readonly ModelRateContribution[], total?: number): ModelRateContribution[] {
  const sums = new Map<string, number>();
  for (const row of rates) {
    if (!Number.isFinite(row.tokensPerSecond) || row.tokensPerSecond <= 1e-9) continue;
    const key = floatingModelUsageKey(row.model);
    sums.set(key, (sums.get(key) ?? 0) + row.tokensPerSecond);
  }
  const known = [...sums.values()].reduce((a, b) => a + b, 0), target = total ?? known;
  if (!Number.isFinite(known) || !Number.isFinite(target) || target <= 0) return [];
  if (known > target) for (const [key, value] of sums) sums.set(key, value * target / known);
  if (target - known > 1e-9) sums.set("unknown", (sums.get("unknown") ?? 0) + target - known);
  return [...sums].sort(([a], [b]) => compare(a, b)).map(([model, tokensPerSecond]) => ({ model, tokensPerSecond }));
}
const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
export function modelRateValueText(value: number): string { return Number.isFinite(value) && value > 0 ? value.toFixed(1) : "0.0"; }

/** Rings, compact bars, previews and the model legend consume this value. */
export function liveModelRateSnapshot(sources: ModelRateSource[], enabled: boolean,
  mode: "bar" | "agentSpeed", grouping: SpeedColorGrouping): LiveModelRateSnapshot {
  let rows: LiveModelRateRow[] = sources.filter(source => enabled && source.available).flatMap(source =>
    normalizedModelRates(source.rates, source.total).map(rate => ({
      id: source.client + ":" + rate.model, client: source.client, model: rate.model,
      rawModels: [...new Set(source.rates.filter(row => floatingModelUsageKey(row.model) === rate.model).map(row => row.model))].sort(),
      colorKey: grouping === "client" ? "client:" + source.client : rate.model,
      label: modelUsageLabel(rate.model), clientLabel: modelUsageLabel("client:" + source.client),
      tokensPerSecond: rate.tokensPerSecond, share: 0, barFraction: 0,
    })));
  let total = rows.reduce((sum, row) => sum + row.tokensPerSecond, 0);
  if (!Number.isFinite(total)) { rows = []; total = 0; }
  const maximum = Math.max(0, ...rows.map(row => row.tokensPerSecond));
  for (const row of rows) { row.share = total > 0 ? row.tokensPerSecond / total : 0; row.barFraction = maximum > 0 ? row.tokensPerSecond / maximum : 0; }
  rows.sort((a, b) => compare(a.colorKey, b.colorKey) || compare(a.model, b.model) || compare(a.client, b.client));
  const available = enabled && sources.some(source => source.available);
  return { sources, sourceKey: sources.map(source => source.client + ":" + source.sourceKey).join("|"), mode, grouping,
    enabled, available, total, rows,
    modelRates: normalizedModelRates(rows.map(row => ({ model: row.model, tokensPerSecond: row.tokensPerSecond }))),
    colorRates: normalizedModelRates(rows.map(row => ({ model: row.colorKey, tokensPerSecond: row.tokensPerSecond }))),
    status: !enabled ? "实时速率已关闭" : !available ? "实时速率不可用" : total === 0 ? "等待新增输出" : "当前活动速率" };
}

/** Source choice is shared with the three-minute history. Never add both Codex algorithms. */
export function activityRateSources(codex: readonly ModelRateContribution[],
  upstream: readonly { client: string; model: string; outputTps: number }[], allowed: readonly string[],
  mode: "bar" | "agentSpeed", codexOutputRate?: number,
  observation: { sourceKey: string; codexAvailable: boolean; upstreamAvailable: Record<string, boolean>; observedAt: number } =
    { sourceKey: "", codexAvailable: true, upstreamAvailable: {}, observedAt: 0 }): ModelRateSource[] {
  return [...new Set(allowed)].sort().map(client => ({ client, sourceKey: observation.sourceKey,
    observedAt: observation.observedAt,
    available: client === "codex" && mode === "bar" ? observation.codexAvailable : observation.upstreamAvailable[client] !== false,
    rates: client === "codex" && mode === "bar" ? codex : upstream.filter(row => row.client === client)
      .map(row => ({ model: row.model, tokensPerSecond: row.outputTps })),
    total: client === "codex" && mode === "bar" ? codexOutputRate : undefined,
  }));
}

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
