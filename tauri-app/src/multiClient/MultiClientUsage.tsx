import type { DashboardSnapshot } from "../types/dashboard";
import { clientIsAvailable, codexQuotaProvider, projectClientChart, unavailableQuota, type ClientDetection, type ClientQuotaReading, type ClientTrendBucket, type ClientChartPoint } from "./multiClientProduct";
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";

export type UsageClient = "claudeCode" | "claudeDesktop" | "deepseek" | "gemini" | "opencode";
export const clientNames: Record<UsageClient, string> = {
  claudeCode: "Claude Code", claudeDesktop: "Claude Desktop", deepseek: "DeepSeek / DSH", gemini: "Gemini CLI", opencode: "OpenCode",
};
export interface ClientPreference {
  client: UsageClient; enabled: boolean; showSidebar: boolean; showQuota?: boolean; showMenuBar: boolean; color: string; order: number; style: string; path: string;
}
interface Summary {
  client: UsageClient; model: string; inputTokens: number; outputTokens: number; cacheReadTokens: number | null;
  cacheWriteTokens: number | null; reasoningTokens: number | null; requests: number; lastSeen: string; incompleteFields?: boolean; apiCostUSD?:number|null; unpricedRequests?:number; cacheReadComplete?:boolean;
}
export interface Snapshot { detections?: ClientDetection[]; trendBuckets?: ClientTrendBucket[]; dailyBuckets?: ClientTrendBucket[]; quotas?: ClientQuotaReading[]; preferences: ClientPreference[]; summaries: Summary[]; diagnostics: string[]; updatedAt: string | null; }
export const defaultClientPreferences: ClientPreference[] = (Object.keys(clientNames) as UsageClient[]).map((client, order) => ({
  client, enabled: false, showSidebar: false, showQuota: false, showMenuBar: false, color: { claudeCode: "#D97757", claudeDesktop: "#D97757", deepseek: "#4D6BFE", gemini: "#4796E4", opencode: "#B7B1B1" }[client], order, style: "compact", path: "",
}));
function hasRuntime() { return typeof window !== "undefined" && isTauriRuntimeAvailable(); }
const initial: Snapshot = { preferences: defaultClientPreferences, summaries: [], diagnostics: [], updatedAt: null };
export const tokenAmount = (value: number | null) => value === null ? "—" : value.toLocaleString();
let cached = initial;
let cacheError = "";
let pending: Promise<void> | null = null;
let timer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();
let revision = 0;
const emit = () => { revision += 1; listeners.forEach(listener => listener()); };
function validSnapshot(value: unknown): value is Snapshot {
  const v = value as Snapshot | null;
  return !!v && Array.isArray(v.preferences) && Array.isArray(v.summaries) && Array.isArray(v.diagnostics);
}
async function refreshShared() {
  if (pending || !hasRuntime()) return pending;
  pending = (async () => {
    try {
      const next = await callCommandStrict<unknown>("refresh_multi_client_usage");
      if (validSnapshot(next)) { cached = next; cacheError = ""; }
      else { cacheError = "本地用量接口暂不可用，保留已读取的数据"; }
    } catch (error) { cacheError = String(error); }
    finally { pending = null; emit(); }
  })();
  emit();
  return pending;
}
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (listeners.size === 1 && hasRuntime()) {
    const poll = async () => {
      // Each WebView shares one poll; hidden windows keep no scanning timer work.
      if (typeof document === "undefined" || !document.hidden) await refreshShared();
      if (listeners.size) timer = setTimeout(poll, 60_000);
    };
    void poll();
  }
  return () => { listeners.delete(listener); if (!listeners.size) clearTimeout(timer); };
}
export function useMultiClientUsage() {
  useSyncExternalStore(subscribe, () => revision, () => 0);
  const snapshot = cached;
  const [saving, setSaving] = useState(false);
  async function save(preferences: ClientPreference[]) {
    if (saving || !hasRuntime()) return false;
    setSaving(true);
    try {
      if (pending) await pending;
      const saved = await callCommandStrict<ClientPreference[]>("save_multi_client_usage_preferences", { preferences });
      if (Array.isArray(saved)) { cached = { ...cached, preferences: saved }; emit(); }
      await refreshShared();
      return Array.isArray(saved);
    } catch (error) { cacheError = String(error); emit(); return false; }
    finally { setSaving(false); }
  }
  return { snapshot, error: cacheError, busy: saving || !!pending, refresh: refreshShared, save };
}

interface QuotaDisplay { overviewSidebar: boolean; codexSidebar: boolean; codexColor: string; claudeSidebar: boolean; claudeColor: string; claudeFirst: boolean; claudeStyle: string; }
const quotaDefaults: QuotaDisplay = { overviewSidebar: false, codexSidebar: true, codexColor: "#b6ef75", claudeSidebar: false, claudeColor: "#d87757", claudeFirst: false, claudeStyle: "compact" };
const quotaKey = "multiClient.quotaDisplay.v1";
function readQuotaDisplay(): QuotaDisplay {
  try {
    const value = JSON.parse(localStorage.getItem(quotaKey) ?? "null");
    if (!value || typeof value !== "object") return quotaDefaults;
    return { ...quotaDefaults,
      overviewSidebar: value.overviewSidebar === true, codexSidebar: value.codexSidebar !== false, claudeSidebar: value.claudeSidebar === true,
      claudeFirst: value.claudeFirst === true, claudeStyle: value.claudeStyle === "detailed" ? "detailed" : "compact",
      codexColor: /^#[0-9a-f]{6}$/i.test(value.codexColor ?? "") ? value.codexColor : quotaDefaults.codexColor,
      claudeColor: /^#[0-9a-f]{6}$/i.test(value.claudeColor ?? "") ? value.claudeColor : quotaDefaults.claudeColor,
    };
  } catch { return quotaDefaults; }
}
export function useQuotaDisplay() {
  const [value, setValue] = useState(readQuotaDisplay);
  useEffect(() => {
    const read = () => setValue(readQuotaDisplay());
    window.addEventListener("storage", read); window.addEventListener(quotaKey, read);
    return () => { window.removeEventListener("storage", read); window.removeEventListener(quotaKey, read); };
  }, []);
  const change = (patch: Partial<QuotaDisplay>) => {
    const next = { ...value, ...patch }; localStorage.setItem(quotaKey, JSON.stringify(next)); setValue(next);
    window.dispatchEvent(new Event(quotaKey));
  };
  return { value, change };
}
export function MultiClientUsageSettings() {
  const quotaDisplay = useQuotaDisplay();
  const [showCustom, setShowCustom] = useState(false);
  const { snapshot, error, busy, refresh, save } = useMultiClientUsage();
  function change(client: UsageClient, patch: Partial<ClientPreference>) {
    void save(snapshot.preferences.map(value => value.client === client ? { ...value, ...patch } : value));
  }
  const visiblePreferences = snapshot.preferences.filter(p => showCustom || clientIsAvailable(p.client, snapshot.detections ?? [], snapshot.preferences, snapshot.summaries));
  function move(index: number, delta: number) {
    const values = [...snapshot.preferences];
    const current = visiblePreferences.indexOf(values[index]);
    const target = values.indexOf(visiblePreferences[current + delta]);
    if (target < 0) return;
    [values[index], values[target]] = [values[target], values[index]];
    void save(values.map((value, order) => ({ ...value, order })));
  }
  return <section className="multi-client-settings" aria-label="多客户端用量设置">
    <header><h3>多客户端 Token 用量</h3><button disabled={busy} onClick={() => void refresh()}>读取本地记录</button></header>
    <p>只读本地日志，各客户端账本与 Codex 并列保存。关闭读取或删除原会话，不会删除已经记录的用量。</p>
    <MultiClientDiscoveryNotice />

    {snapshot.preferences.map((preference, index) => (showCustom || clientIsAvailable(preference.client, snapshot.detections ?? [], snapshot.preferences, snapshot.summaries)) && <fieldset key={preference.client} disabled={busy || !hasRuntime()}>
      <legend style={{ color: preference.color }}>{clientNames[preference.client]}</legend>
      <div className="multi-client-controls">
        <label><input type="checkbox" checked={preference.enabled} onChange={e => change(preference.client, { enabled: e.target.checked })} />读取本地用量</label>

        <label><input type="checkbox" checked={preference.showSidebar} onChange={e => change(preference.client, { showSidebar: e.target.checked })} />侧栏</label>
        <label><input type="checkbox" checked={preference.showMenuBar} onChange={e => change(preference.client, { showMenuBar: e.target.checked })} />菜单栏 / 托盘</label>
        <input aria-label={`${clientNames[preference.client]}颜色`} type="color" value={preference.color} onChange={e => change(preference.client, { color: e.target.value })} />
        <select aria-label={`${clientNames[preference.client]}显示样式`} value={preference.style} onChange={e => change(preference.client, { style: e.target.value })}>
          <option value="compact">紧凑</option><option value="detailed">详细</option>
        </select>
        <button disabled={visiblePreferences.indexOf(preference) === 0} onClick={() => move(index, -1)} aria-label={`上移${clientNames[preference.client]}`}>↑</button>
        <button disabled={visiblePreferences.indexOf(preference) === visiblePreferences.length - 1} onClick={() => move(index, 1)} aria-label={`下移${clientNames[preference.client]}`}>↓</button>
      </div>
      <input className="multi-client-path" aria-label={`${clientNames[preference.client]}日志路径`} defaultValue={preference.path} placeholder="自动发现；也可指定本地日志目录或文件"
        onBlur={e => { if (e.target.value !== preference.path) change(preference.client, { path: e.target.value }); }} />
      {preference.client === "claudeDesktop" && <p>仅支持本地 Code / Agent 会话；云端聊天未落地的用量无法读取。</p>}
    </fieldset>)}
    <button onClick={()=>setShowCustom(value=>!value)}>{showCustom ? "只显示已发现的客户端" : "手动接入其他日志目录"}</button>
    <ClaudeLocalQuotaPanel />
    <p>Claude 额度只读已有状态栏缓存，不安装钩子、不读取凭据、不联网。没有有效记录时不推算剩余百分比。Codex 额度显示继续使用原有侧栏和状态栏设置。</p>
    {error && <p role="alert">{error}</p>}
    {snapshot.diagnostics.map((line, index) => <p className="multi-client-note" key={index}>{line}</p>)}
  </section>;
}

export function MultiClientUsageTable({ snapshot }: { snapshot: Snapshot }) {
  return <div className="multi-client-table-wrap"><table className="multi-client-table"><thead><tr>
    <th>客户端 / 模型</th><th>输入</th><th>输出</th><th>缓存读取</th><th>缓存写入</th><th>思考¹</th><th>请求</th>
  </tr></thead><tbody>{snapshot.preferences.flatMap(preference => snapshot.summaries.filter(row => row.client === preference.client).map(row => <tr key={`${row.client}:${row.model}`}>
    <td><span style={{ color: preference.color }}>{clientNames[row.client]}</span><small>{row.model}</small></td>
    <td>{tokenAmount(row.inputTokens)}</td><td>{tokenAmount(row.outputTokens)}</td><td>{tokenAmount(row.cacheReadTokens)}</td>
    <td>{tokenAmount(row.cacheWriteTokens)}</td><td>{tokenAmount(row.reasoningTokens)}</td><td>{row.requests}</td>
  </tr>))}</tbody></table></div>;
}
const discoveryKey = "multiClient.discoveryAcknowledged.v1";
function useDiscoveryAcknowledgements() {
  const read = () => { try { const values=JSON.parse(localStorage.getItem(discoveryKey) ?? "[]"); return new Set<string>(Array.isArray(values) ? values : []); } catch { return new Set<string>(); } };
  const [seen, setSeen] = useState(read);
  useEffect(()=>{ const update=()=>setSeen(read()); window.addEventListener(discoveryKey, update); window.addEventListener("storage",update); return ()=>{window.removeEventListener(discoveryKey,update);window.removeEventListener("storage",update);};},[]);
  return {seen, acknowledge(client:string) { const next=read();next.add(client);localStorage.setItem(discoveryKey,JSON.stringify([...next]));setSeen(next);window.dispatchEvent(new Event(discoveryKey)); }};
}
export function MultiClientDiscoveryNotice() {
  const {snapshot, save, busy} = useMultiClientUsage();
  const {seen, acknowledge} = useDiscoveryAcknowledgements();
  return <>{(snapshot.detections ?? []).filter(d=>!seen.has(d.client) && !snapshot.preferences.some(p=>p.client===d.client && p.enabled)).slice(0,1).map(d=><div className="multi-client-discovery" key={d.client}>
    <div><strong>发现 {clientNames[d.client as UsageClient] ?? d.client}</strong><small>启用后在本机统计 Token，随时可关闭。</small></div>
    <button disabled={busy} onClick={async()=>{if (await save(snapshot.preferences.map(p=>p.client===d.client ? {...p,enabled:true,showSidebar:true,showQuota:p.client==="claudeCode"}:p))) acknowledge(d.client);}}>启用</button>
    <button onClick={()=>acknowledge(d.client)}>暂不启用</button>
  </div>)}</>;
}
export function ClientQuotaPanel({reading, compact=false}: {reading:ClientQuotaReading;compact?:boolean}) {
  return <div className={compact ? "multi-client-quota-inline" : "multi-client-quota"} title={reading.notice}>
    {reading.state === "available" ? reading.windows.map(w=><span key={w.label}>{w.label} 剩余 {(100-w.usedPercent).toFixed(0)}%</span>) : <span>{reading.state === "notConnected" ? "额度未接入" : "额度不可用"}</span>}
    {!compact && <small>{reading.notice}</small>}
  </div>;
}
function clientName(client:string) { return client === "codex" ? "Codex" : client === "all" ? "合计" : clientNames[client as UsageClient] ?? client; }
export function ClientUsageChart({points, colors, combined=false}: {points:ClientChartPoint[];colors:Record<string,string>;combined?:boolean}) {
  const [hover, setHover] = useState<number | null>(null);
  const starts=[...new Set(points.map(p=>p.startUnix))].sort((a,b)=>a-b);
  const grouped=starts.map(start=>points.filter(p=>p.startUnix===start));
  const max=Math.max(1,...grouped.map(rows=>rows.reduce((n,p)=>n+p.tokens,0)));
  const width=840, height=150, step=width/Math.max(1,starts.length);
  return <div className="multi-client-chart">
    <svg viewBox="0 0 900 200" role="img" aria-label="按客户端区分的 Token 用量趋势">
      {[0,0.5,1].map(f=><g key={f}><line x1="48" x2="888" y1={160-f*height} y2={160-f*height} stroke="currentColor" opacity="0.13"/><text x="42" y={164-f*height} textAnchor="end">{(max*f).toLocaleString("en",{notation:"compact"})}</text></g>)}
      {grouped.map((rows,i)=>{let y=160; const bars=combined ? [{client:"all",tokens:rows.reduce((n,p)=>n+p.tokens,0)}] : rows;return <g key={starts[i]} tabIndex={0} role="button" aria-label={new Date(starts[i]*1000).toISOString()+" "+rows.map(p=>clientName(p.client)+" "+p.tokens).join(", ")} onFocus={()=>setHover(i)} onMouseEnter={()=>setHover(i)} onClick={()=>setHover(i)} onKeyDown={e=>{if(e.key==="Enter" || e.key===" "){e.preventDefault();setHover(i);}}}>
        <rect x={48+i*step} y="0" width={step} height="170" fill="transparent"/>
        {bars.map(p=>{const h=p.tokens/max*height;y-=h;return <rect key={p.client} x={50+i*step} y={y} width={Math.max(1,step-4)} height={h} fill={colors[p.client] ?? "#72b743"} rx="2" opacity={hover===null || hover===i ? 1:0.55}/>;})}
        {(i===0 || i===Math.floor(starts.length/2) || i===starts.length-1) && <text x={48+(i+0.5)*step} y="188" textAnchor="middle">{new Date(starts[i]*1000).toLocaleString(undefined,{timeZone:"UTC",month:"2-digit",day:"2-digit",hour:"2-digit",hour12:false})}</text>}
      </g>;})}
    </svg>
    <div className="multi-client-chart-readout" aria-live="polite">{hover !== null && grouped[hover] ? <>{new Date(starts[hover]*1000).toLocaleString(undefined,{timeZone:"UTC"})} UTC · {grouped[hover].map(p=>`${clientName(p.client)} ${p.tokens.toLocaleString()}`).join(" · ")}</> : "移入或点选柱形，查看每个客户端的精确数值"}</div>
  </div>;
}
export function MultiClientUsageSidebarRows({codexTokens}: {codexTokens?:number}) {
  const {snapshot}=useMultiClientUsage(); const {value:display}=useQuotaDisplay();
  const quota=display.claudeSidebar ? <div style={{color:display.claudeColor}}><ClaudeLocalQuotaPanel compact/></div>:null;
  const total=(codexTokens ?? 0)+snapshot.summaries.filter(s=>snapshot.preferences.some(p=>p.client===s.client && p.enabled)).reduce((n,s)=>n+s.inputTokens+s.outputTokens,0);
  return <>{display.overviewSidebar && <div className="multi-client-sidebar-row"><span>合计 · 已记录</span><strong>{total.toLocaleString("en",{notation:"compact"})}</strong>{codexTokens===undefined && <span>Codex 暂不可用</span>}</div>}{display.claudeFirst && quota}
    {snapshot.preferences.filter(p=>p.showSidebar).map(p=><div className="multi-client-sidebar-row" key={p.client} style={{color:p.color}}><span>{clientNames[p.client]}</span><strong>{snapshot.summaries.some(s=>s.client===p.client)?snapshot.summaries.filter(s=>s.client===p.client).reduce((n,s)=>n+s.inputTokens+s.outputTokens,0).toLocaleString("en",{notation:"compact"}):"—"}</strong>{p.style==="detailed" && <span>累计 Token</span>}{p.showQuota && <ClientQuotaPanel compact reading={snapshot.quotas?.find(q=>q.client===p.client) ?? unavailableQuota(p.client)}/>}</div>)}{!display.claudeFirst && quota}</>;
}
export function ClaudeLocalQuotaPanel({compact=false}:{compact?:boolean}) {
  const {snapshot}=useMultiClientUsage();
  return <section className={compact ? "multi-client-quota-inline" : "multi-client-quota"}><h4>Claude Code 额度</h4><ClientQuotaPanel compact={compact} reading={snapshot.quotas?.find(q=>q.client==="claudeCode") ?? unavailableQuota("claudeCode")}/>{!compact && <small>联网额度：关闭（尚未接入）</small>}</section>;
}
