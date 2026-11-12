import type { QuotaSnapshot } from "../types/quota";
import quotaPresentation from "../../../Sources/CodexTokenBar/Resources/client-quota-presentation.json" with {type:"json"};
export interface ClientDetection { client: string; evidence: string; }
export interface ClientTrendBucket {
  client: string; startUnix: number; inputTokens: number; outputTokens: number;
  cacheReadTokens?: number | null; cacheWriteTokens?: number | null; reasoningTokens?: number | null; requests: number;
  apiCostMicroUSD?: number | null; unpricedRequests?: number;
  model?: string | null; cacheReadComplete?: boolean | null; cacheWriteComplete?: boolean | null;
}
export interface ClientQuotaReading {
  client: string; state: string; source: string;
  windows: { id?: string | null; label: string; usedPercent: number; resetsAt: string | null }[]; notice: string;
  capturedAt?: string | null;
}
export interface ClientQuotaProvider { readonly allowsNetwork: false; reading(): ClientQuotaReading; }
const quotaStates:Record<string,{label:string;compact:string}>=quotaPresentation.states;
export const clientQuotaStatusText=(state:string)=>quotaStates[state]?.label??"额度不可用";
export const clientQuotaCompactStatus=(state?:string)=>state?quotaStates[state]?.compact??"—":"—";
export const quotaPercentNumber=(value:number)=>Number.isFinite(value)?value.toFixed(2).replace(/\.?0+$/, ""):"—";
export function quotaSampleStatus(client:string,resetsAt:string|null|undefined,now=Date.now()):string {
  if(client!=="claudeDesktop")return "";
  const reset=resetsAt?Date.parse(resetsAt):NaN;
  return Number.isFinite(reset)&&reset<=now?"重置待更新":"缓存";
}
export function quotaAutomaticallyVisible(reading:ClientQuotaReading,now=Date.now()):boolean {
  if(reading.source==="unsupported" || !["claudeCode","claudeDesktop","antigravity"].includes(reading.client)
    || !["available","stale","cached"].includes(reading.state) || !reading.capturedAt) return false;
  const captured=Date.parse(reading.capturedAt);
  return Number.isFinite(captured) && captured<=now+60_000 && now-captured<=3*24*60*60*1000;
}
export function quotaReadingIsPresent(reading:ClientQuotaReading,detected=false):boolean {
  return reading.source!=="unsupported"&&(detected||reading.state==="api"||reading.windows.length>0||Boolean(reading.capturedAt));
}
export function codexQuotaProvider(quota?: QuotaSnapshot): ClientQuotaProvider {
  return { allowsNetwork: false, reading() {
    const windows = [quota?.fiveHour, quota?.sevenDay].filter(value => value?.availability === "measured" && value.usedPercent !== null)
      .map(value => ({ label: value!.label, usedPercent: value!.usedPercent!, resetsAt: value!.resetsAt ?? null }));
    return { client: "codex", state: windows.length ? "available" : "unavailable", source: "codex-existing", windows, notice: "沿用 Codex 现有额度刷新，不额外请求" };
  } };
}
export const claudeQuotaSetup = "可手动配置本地 statusLine 命令（TokenBarClaudeLocal / ClaudeLocalReader），也兼容已有 claude-monitor --statusline 缓存。本软件不会安装工具、修改 Claude 配置或联网。";
export function unavailableQuota(client: string): ClientQuotaReading {
  if (client === "antigravity") return {client,state:"notConnected",source:"local-antigravity-state",windows:[],notice:"未读到可用的 Antigravity 本地额度缓存。只读已有文件，不启动客户端、不发网络请求。"};
  return {client, state:"notConnected", source:client === "claudeCode" ? "local-statusline" : client === "claudeDesktop" ? "local-desktop-history" : "unsupported", windows:[], notice:client === "claudeCode" ? claudeQuotaSetup : client === "claudeDesktop" ? "未读到可用的 Desktop 本地额度历史。仅读取 plan-usage-history.json，不发网络请求。" : "尚无本地额度提供者；Token 用量仍可读取。联网额度保持关闭。"};
}

export function claudeQuotaFromLocalCache(value: {
  state:string;source?:string|null;capturedAt?:string|null;fiveHour?:{usedPercent:number;resetsAt:string|null}|null;
  sevenDay?:{usedPercent:number;resetsAt:string|null}|null;
}, client: "claudeCode" | "claudeDesktop" = "claudeCode"):ClientQuotaReading {
  if(client === "claudeCode" && value.state === "api") return {client,state:"api",source:"local-config",windows:[],notice:"API 接入 · 订阅额度不适用"};
  const windows:ClientQuotaReading["windows"]=[];
  if(value.state === "available") for(const [label,window] of [["5h",value.fiveHour],["7d",value.sevenDay]] as const) {
    if(window && Number.isFinite(window.usedPercent) && window.usedPercent>=0 && window.usedPercent<=100)
      windows.push({label,usedPercent:window.usedPercent,resetsAt:window.resetsAt});
  }
  const desktop=client==="claudeDesktop";
  const httpCache=desktop && value.source==="local-desktop-http-cache";
  const notice=httpCache ? (value.state==="available" ? "Desktop 上次用量采样，保留官方重置时间；重置后等待客户端更新，不推算新余额。可在 Claude 中打开用量更新缓存。不发送网络请求，未验证当前账号。" : "Desktop 本地 HTTP 缓存不可用；不会唤醒客户端或请求刷新。") : desktop ? "Desktop 上次本地用量采样；不因闲置清空。文件不含重置时间，无法确认当前周期余额，不与 CLI 额度合并。未验证当前账号。" : "只读取本地 CLI 额度缓存，不联网。";
  const state=windows.length?"available":desktop?(value.state==="stale"?"stale":value.state==="missing"?"notConnected":"unavailable"):value.state;
  return {client,state,source:value.source??(desktop?"local-desktop-history":"local-statusline"),windows,notice,capturedAt:value.capturedAt??null};
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
