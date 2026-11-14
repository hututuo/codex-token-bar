import type { RecentUsagePoint } from "../types/dashboard";
import type { ClientQuotaReading } from "./multiClientProduct";

export interface ClientQuotaHistorySample {
  windowId: string;
  observedAt: number;
  usedPercent: number;
  resetsAt: number | null;
  source?: string;
}

export interface ClientQuotaChartSource { id: string; client: string; pool: string; title: string; historySource?: string }
const sources: ClientQuotaChartSource[] = [
  { id: "codex", client: "codex", pool: "", title: "Codex" },
  { id: "claudeCode", client: "claudeCode", pool: "", title: "Claude CLI" },
  { id: "claudeDesktop", client: "claudeDesktop", pool: "", title: "Claude Desktop" },
  { id: "antigravity:gemini", client: "antigravity", pool: "gemini", title: "Antigravity · Gemini" },
  { id: "antigravity:3p", client: "antigravity", pool: "3p", title: "Antigravity · 第三方模型" },
];
export function quotaChartSources(clients: readonly string[], readings: readonly ClientQuotaReading[] = []) {
  const base = sources.filter(source => clients.includes(source.client));
  const earlier = base.flatMap(source => {
    const reading = readings.find(reading => reading.client === source.client);
    const recorded = new Set((reading?.history ?? []).map(sample => sample.source ?? reading?.source));
    recorded.delete(reading?.source);
    return [...recorded].filter((origin): origin is string => Boolean(origin)).map(origin => ({
      ...source, id: source.id + "@" + origin, historySource: origin, title: source.title + " · 历史采样",
    }));
  });
  return base.concat(earlier);
}
export function resolveQuotaChartSource(selection: string, clients: readonly string[], readings: readonly ClientQuotaReading[] = []) {
  const options = quotaChartSources(clients, readings);
  return options.find(source => source.id === selection) ?? options[0];
}
function windowId(source: ClientQuotaChartSource, period: "5h" | "7d") {
  if (source.client !== "antigravity") return period;
  return source.pool + "-" + (period === "7d" ? "weekly" : "5h");
}

/** The existing chart consumes fractions. Persisted samples retain percent precision. */
export function applyClientQuotaHistory(
  points: RecentUsagePoint[], reading: ClientQuotaReading | undefined,
  source: ClientQuotaChartSource | undefined, interval: number, now = Date.now() / 1000,
): RecentUsagePoint[] {
  const history = (reading?.history ?? []).filter(sample =>
    (sample.source ?? reading?.source) === (source?.historySource ?? reading?.source));
  const samples = history.filter(sample => Number.isFinite(sample.observedAt) && sample.observedAt > 0
    && sample.observedAt <= now && Number.isFinite(sample.usedPercent) && sample.usedPercent >= 0 && sample.usedPercent <= 100)
    .sort((a, b) => a.observedAt - b.observedAt);
  let axis = points;
  if (!axis.length && samples.length) {
    const count = interval === 300 ? 288 : interval === 3600 ? 168 : 120;
    const end = Math.floor(now / interval) * interval;
    axis = Array.from({ length: count }, (_, index) => ({
      label: "", startUnix: end - (count - index) * interval, tokens: 0, calls: 0,
      inputTokens: 0, outputTokens: 0, cachedInputTokens: 0, cacheHitRate: null,
      fiveHourRemainingPercent: null, sevenDayRemainingPercent: null,
    }));
  }
  if (source?.client === "codex") return axis;
  if (!source) return axis.map(point => ({ ...point, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null }));
  function values(period: "5h" | "7d") {
    const rows = samples.filter(sample => sample.windowId === windowId(source!, period));
    let cursor = 0;
    return axis.map(point => {
      const end = Math.min(point.startUnix + interval - 0.000001, now);
      const first = cursor;
      while (cursor < rows.length && rows[cursor].observedAt <= end) cursor += 1;
      const latest = rows[cursor - 1];
      if (!latest) return null;
      const observedInBucket = cursor > first && latest.observedAt >= point.startUnix;
      const fresh = end - latest.observedAt <= 1200;
      const beforeReset = latest.resetsAt == null || end < latest.resetsAt;
      return observedInBucket || fresh && beforeReset ? (100 - latest.usedPercent) / 100 : null;
    });
  }
  const five = values("5h"), seven = values("7d");
  return axis.map((point, index) => ({ ...point,
    fiveHourRemainingPercent: five[index], sevenDayRemainingPercent: seven[index],
    fiveHourCycleId: null, sevenDayCycleId: null,
  }));
}
