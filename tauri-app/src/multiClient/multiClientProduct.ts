import type { QuotaSnapshot } from "../types/quota";
export interface ClientDetection { client: string; evidence: string; }
export interface ClientTrendBucket {
  client: string; startUnix: number; inputTokens: number; outputTokens: number;
  cacheReadTokens?: number | null; cacheWriteTokens?: number | null; reasoningTokens?: number | null; requests: number;
  apiCostMicroUSD?: number | null; unpricedRequests?: number;
}
export interface ClientQuotaReading {
  client: string; state: string; source: string;
  windows: { label: string; usedPercent: number; resetsAt: string | null }[]; notice: string;
  capturedAt?: string | null;
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
  return {client, state:"notConnected", source:client === "claudeCode" ? "local-statusline" : client === "claudeDesktop" ? "local-desktop-history" : "unsupported", windows:[], notice:client === "claudeCode" ? claudeQuotaSetup : client === "claudeDesktop" ? "未读到可用的 Desktop 本地额度历史。仅读取 plan-usage-history.json，不发网络请求。" : "尚无本地额度提供者；Token 用量仍可读取。联网额度保持关闭。"};
}

export function claudeQuotaFromLocalCache(value: {
  state:string;capturedAt?:string|null;fiveHour?:{usedPercent:number;resetsAt:string|null}|null;
  sevenDay?:{usedPercent:number;resetsAt:string|null}|null;
}, client: "claudeCode" | "claudeDesktop" = "claudeCode"):ClientQuotaReading {
  if(client === "claudeCode" && value.state === "api") return {client,state:"api",source:"local-config",windows:[],notice:"API 接入 · 订阅额度不适用"};
  const windows:ClientQuotaReading["windows"]=[];
  if(value.state === "available") for(const [label,window] of [["5h",value.fiveHour],["7d",value.sevenDay]] as const) {
    if(window && Number.isFinite(window.usedPercent) && window.usedPercent>=0 && window.usedPercent<=100)
      windows.push({label,usedPercent:window.usedPercent,resetsAt:window.resetsAt});
  }
  const desktop=client==="claudeDesktop";
  const notice=desktop ? value.state==="stale" ? "Desktop 本地采样超过 20 分钟，已过期。官方后台轮询可能暂停；本软件不会唤醒轮询或发网络请求。" : "Desktop 本地历史采样；未验证当前账号。文件不含重置时间，不与 CLI 额度合并。" : "只读取本地 CLI 额度缓存，不联网。";
  const state=windows.length?"available":desktop?(value.state==="stale"?"stale":value.state==="missing"?"notConnected":"unavailable"):value.state;
  return {client,state,source:desktop?"local-desktop-history":"local-statusline",windows,notice,capturedAt:value.capturedAt??null};
}
export interface ClientChartPoint { client: string; startUnix: number; tokens: number; }
export function projectClientChart(codex: {startUnix:number;tokens:number}[], others: ClientTrendBucket[], days: number, now: number, allowed: string[]): ClientChartPoint[] {
  const step = days === 1 ? 300 : days === 7 ? 3600 : 21600, count = days * 86400 / step + 1;
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
