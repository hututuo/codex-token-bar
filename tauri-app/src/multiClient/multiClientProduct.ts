import type { QuotaSnapshot } from "../types/quota";
export interface ClientDetection { client: string; evidence: string; }
export interface ClientTrendBucket {
  client: string; startUnix: number; inputTokens: number; outputTokens: number;
  cacheReadTokens?: number | null; cacheWriteTokens?: number | null; reasoningTokens?: number | null; requests: number;
}
export interface ClientQuotaReading {
  client: string; state: string; source: string;
  windows: { label: string; usedPercent: number; resetsAt: string | null }[]; notice: string;
}
export interface ClientQuotaProvider { readonly allowsNetwork: false; reading(): ClientQuotaReading; }
export function codexQuotaProvider(quota?: QuotaSnapshot): ClientQuotaProvider {
  return { allowsNetwork: false, reading() {
    const windows = [quota?.fiveHour, quota?.sevenDay].filter(value => value?.availability === "measured" && value.usedPercent !== null)
      .map(value => ({ label: value!.label, usedPercent: value!.usedPercent!, resetsAt: value!.resetsAt ?? null }));
    return { client: "codex", state: windows.length ? "available" : "unavailable", source: "codex-existing", windows, notice: "沿用 Codex 现有额度刷新，不额外请求" };
  } };
}
export const claudeQuotaSetup = "在 Claude Code 的 statusLine 设置中配置已安装的 claude-monitor --statusline，使用一次 Claude 后点击刷新。只读取 ~/.claude-monitor/statusline/latest.json；不会安装工具或修改 Claude 配置。";
export function unavailableQuota(client: string): ClientQuotaReading {
  return {client, state:"notConnected", source:client === "claudeCode" ? "local-statusline" : "unsupported", windows:[], notice:client === "claudeCode" ? claudeQuotaSetup : "尚无本地额度提供者；Token 用量仍可读取。联网额度保持关闭。"};
}
export interface ClientChartPoint { client: string; startUnix: number; tokens: number; }
export function projectClientChart(codex: {startUnix:number;tokens:number}[], others: ClientTrendBucket[], days: number, now: number, allowed: string[]): ClientChartPoint[] {
  const step = days === 1 ? 3600 : 86400, count = days === 1 ? 24 : days;
  const last = Math.floor(now / step) * step, first = last - (count - 1) * step;
  const sums = new Map<string, number>();
  const clients = new Set(allowed);
  function add(client: string, time: number, tokens: number) {
    const start = Math.floor(time / step) * step;
    if (!clients.has(client) || !Number.isFinite(tokens) || time > now || start < first || start > last) return;
    const key = `${client}:${start}`; sums.set(key, (sums.get(key) ?? 0) + Math.max(0, tokens));
  }
  codex.forEach(p => add("codex", p.startUnix, p.tokens));
  others.forEach(p => add(p.client, p.startUnix, p.inputTokens + p.outputTokens));
  return [...clients].sort().flatMap(client => Array.from({length:count}, (_, i) => {
    const startUnix = first + i * step; return {client, startUnix, tokens:sums.get(`${client}:${startUnix}`) ?? 0};
  }));
}
export function clientIsAvailable(client: string, detections: ClientDetection[], preferences: {client:string;enabled:boolean;path:string}[], summaries: {client:string}[]) {
  return detections.some(value => value.client === client) || preferences.some(value => value.client === client && (value.enabled || !!value.path)) || summaries.some(value => value.client === client);
}
