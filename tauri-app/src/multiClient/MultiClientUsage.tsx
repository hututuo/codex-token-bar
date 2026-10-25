import { useEffect, useState, useSyncExternalStore } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";

export type UsageClient = "claudeCode" | "claudeDesktop" | "deepseek" | "gemini" | "opencode";
export const clientNames: Record<UsageClient, string> = {
  claudeCode: "Claude Code", claudeDesktop: "Claude Desktop", deepseek: "DeepSeek / DSH", gemini: "Gemini CLI", opencode: "OpenCode",
};
export interface ClientPreference {
  client: UsageClient; enabled: boolean; showSidebar: boolean; showMenuBar: boolean; color: string; order: number; style: string; path: string;
}
interface Summary {
  client: UsageClient; model: string; inputTokens: number; outputTokens: number; cacheReadTokens: number | null;
  cacheWriteTokens: number | null; reasoningTokens: number | null; requests: number; lastSeen: string; incompleteFields?: boolean;
}
interface Snapshot { preferences: ClientPreference[]; summaries: Summary[]; diagnostics: string[]; updatedAt: string | null; }
export const defaultClientPreferences: ClientPreference[] = (Object.keys(clientNames) as UsageClient[]).map((client, order) => ({
  client, enabled: false, showSidebar: false, showMenuBar: false, color: ["#d87757", "#b875c7", "#507de8", "#36a183", "#b79a4b"][order], order, style: "compact", path: "",
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
function useMultiClientUsage() {
  useSyncExternalStore(subscribe, () => revision, () => 0);
  const snapshot = cached;
  const [saving, setSaving] = useState(false);
  async function save(preferences: ClientPreference[]) {
    if (saving || !hasRuntime()) return;
    setSaving(true);
    try {
      if (pending) await pending;
      const saved = await callCommandStrict<ClientPreference[]>("save_multi_client_usage_preferences", { preferences });
      if (Array.isArray(saved)) { cached = { ...cached, preferences: saved }; emit(); }
      await refreshShared();
    } catch (error) { cacheError = String(error); emit(); }
    finally { setSaving(false); }
  }
  return { snapshot, error: cacheError, busy: saving || !!pending, refresh: refreshShared, save };
}

interface QuotaDisplay { codexSidebar: boolean; codexColor: string; claudeSidebar: boolean; claudeColor: string; claudeFirst: boolean; claudeStyle: string; }
const quotaDefaults: QuotaDisplay = { codexSidebar: true, codexColor: "#b6ef75", claudeSidebar: false, claudeColor: "#d87757", claudeFirst: false, claudeStyle: "compact" };
const quotaKey = "multiClient.quotaDisplay.v1";
function readQuotaDisplay(): QuotaDisplay {
  try {
    const value = JSON.parse(localStorage.getItem(quotaKey) ?? "null");
    if (!value || typeof value !== "object") return quotaDefaults;
    return { ...quotaDefaults,
      codexSidebar: value.codexSidebar !== false, claudeSidebar: value.claudeSidebar === true,
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
  const { snapshot, error, busy, refresh, save } = useMultiClientUsage();
  function change(client: UsageClient, patch: Partial<ClientPreference>) {
    void save(snapshot.preferences.map(value => value.client === client ? { ...value, ...patch } : value));
  }
  function move(index: number, delta: number) {
    const values = [...snapshot.preferences];
    [values[index], values[index + delta]] = [values[index + delta], values[index]];
    void save(values.map((value, order) => ({ ...value, order })));
  }
  return <section className="multi-client-settings" aria-label="多客户端用量设置">
    <header><h3>多客户端 Token 用量</h3><button disabled={busy} onClick={() => void refresh()}>读取本地记录</button></header>
    <p>只读本地日志，各客户端账本与 Codex 并列保存。关闭读取或删除原会话，不会删除已经记录的用量。</p>
    {snapshot.preferences.map((preference, index) => <fieldset key={preference.client} disabled={busy || !hasRuntime()}>
      <legend style={{ color: preference.color }}>{clientNames[preference.client]}</legend>
      <div className="multi-client-controls">
        <label><input type="checkbox" checked={preference.enabled} onChange={e => change(preference.client, { enabled: e.target.checked })} />读取本地用量</label>
        <label><input type="checkbox" checked={preference.showSidebar} onChange={e => change(preference.client, { showSidebar: e.target.checked })} />侧栏</label>
        <label><input type="checkbox" checked={preference.showMenuBar} onChange={e => change(preference.client, { showMenuBar: e.target.checked })} />菜单栏 / 托盘</label>
        <input aria-label={`${clientNames[preference.client]}颜色`} type="color" value={preference.color} onChange={e => change(preference.client, { color: e.target.value })} />
        <select aria-label={`${clientNames[preference.client]}显示样式`} value={preference.style} onChange={e => change(preference.client, { style: e.target.value })}>
          <option value="compact">紧凑</option><option value="detailed">详细</option>
        </select>
        <button disabled={index === 0} onClick={() => move(index, -1)} aria-label={`上移${clientNames[preference.client]}`}>↑</button>
        <button disabled={index === snapshot.preferences.length - 1} onClick={() => move(index, 1)} aria-label={`下移${clientNames[preference.client]}`}>↓</button>
      </div>
      <input className="multi-client-path" aria-label={`${clientNames[preference.client]}日志路径`} defaultValue={preference.path} placeholder="自动发现；也可指定本地日志目录或文件"
        onBlur={e => { if (e.target.value !== preference.path) change(preference.client, { path: e.target.value }); }} />
      {preference.client === "claudeDesktop" && <p>仅支持本地 Code / Agent 会话；云端聊天未落地的用量无法读取。</p>}
    </fieldset>)}
    <fieldset><legend>额度显示</legend><div className="multi-client-controls">
      <label><input type="checkbox" checked={quotaDisplay.value.codexSidebar} onChange={e => quotaDisplay.change({codexSidebar:e.target.checked})} />侧栏显示 Codex 额度</label>
      <input type="color" aria-label="Codex 额度颜色" value={quotaDisplay.value.codexColor} onChange={e=>quotaDisplay.change({codexColor:e.target.value})} />
      <label><input type="checkbox" checked={quotaDisplay.value.claudeSidebar} onChange={e => quotaDisplay.change({claudeSidebar:e.target.checked})} />侧栏显示 Claude 额度</label>
      <input type="color" aria-label="Claude 额度颜色" value={quotaDisplay.value.claudeColor} onChange={e=>quotaDisplay.change({claudeColor:e.target.value})} />
      <label><input type="checkbox" checked={quotaDisplay.value.claudeFirst} onChange={e => quotaDisplay.change({claudeFirst:e.target.checked})} />Claude 额度排在其他客户端前面</label>
      <select aria-label="Claude 额度样式" value={quotaDisplay.value.claudeStyle} onChange={e=>quotaDisplay.change({claudeStyle:e.target.value})}><option value="compact">紧凑</option><option value="detailed">详细</option></select>
    </div></fieldset>
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
export function MultiClientUsageDashboardCard() {
  const { snapshot, busy, refresh, error } = useMultiClientUsage();
  if (!snapshot.preferences.some(value => value.enabled) && !snapshot.summaries.length) return null;
  return <section className="multi-client-card"><header><h3>其他客户端 · 本地 Token 账本</h3><button disabled={busy} onClick={() => void refresh()}>刷新</button></header>
    <MultiClientUsageTable snapshot={snapshot} />
    {!snapshot.summaries.length && <p>尚无可识别的本地用量记录</p>}
    <p className="multi-client-note">累计已记录；输入包含缓存；¹思考是输出的子集，不重复相加。— 表示来源未提供；部分字段仅汇总已提供值。这里不是订阅剩余额度。</p>
    {error && <p role="alert">{error}</p>}
  </section>;
}
export function MultiClientUsageSidebarRows() {
  const { snapshot } = useMultiClientUsage();
  const {value: display} = useQuotaDisplay();
  const quota = display.claudeSidebar ? <div style={{color:display.claudeColor}}><ClaudeLocalQuotaPanel compact={display.claudeStyle === "compact"} /></div> : null;
  return <>{display.claudeFirst && quota}{snapshot.preferences.filter(value => value.showSidebar).map(preference => <div className="multi-client-sidebar-row" key={preference.client} style={{ color: preference.color }}>
    <span>{clientNames[preference.client]}</span><strong>{snapshot.summaries.some(row => row.client === preference.client) ? snapshot.summaries.filter(row => row.client === preference.client).reduce((sum, row) => sum + row.inputTokens + row.outputTokens, 0).toLocaleString("en", { notation: "compact" }) : "—"}</strong>
    {preference.style === "detailed" && <span>累计 Token</span>}
  </div>)}{!display.claudeFirst && quota}</>;
}
interface LocalQuota { state: string; capturedAt: string | null; fiveHour: {usedPercent:number;resetsAt:string} | null; sevenDay:{usedPercent:number;resetsAt:string} | null; }
export function ClaudeLocalQuotaPanel({compact = false}: {compact?:boolean}) {
  const [quota, setQuota] = useState<LocalQuota>({state:"missing",capturedAt:null,fiveHour:null,sevenDay:null});
  useEffect(() => {
    if (!hasRuntime()) return;
    let disposed = false;
    const read = () => { void callCommandStrict<LocalQuota>("read_claude_local_quota").then(value => { if (!disposed && value && typeof value.state === "string") setQuota(value); }).catch(() => {}); };
    read(); const timer = setInterval(read,60_000);
    return () => { disposed = true; clearInterval(timer); };
  }, []);
  return <section className="multi-client-quota"><h4>{compact ? "Claude 额度" : "Claude Code · 本地状态栏额度"}</h4>
    {quota.state === "available" ? <>
      {quota.fiveHour && <p>5 小时剩余 {(100-quota.fiveHour.usedPercent).toFixed(0)}%{!compact && <> · 重置 {new Date(quota.fiveHour.resetsAt).toLocaleString()}</>}</p>}
      {quota.sevenDay && <p>7 天剩余 {(100-quota.sevenDay.usedPercent).toFixed(0)}%{!compact && <> · 重置 {new Date(quota.sevenDay.resetsAt).toLocaleString()}</>}</p>}
      {!compact && <small>最近 Claude 进程，未绑定账号 · 采集于 {quota.capturedAt && new Date(quota.capturedAt).toLocaleString()}</small>}
    </> : <p>{quota.state === "stale" ? "已过期" : "未采集"}</p>}
  </section>;
}
