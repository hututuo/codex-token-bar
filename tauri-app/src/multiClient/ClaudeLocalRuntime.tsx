import { useCallback, useSyncExternalStore } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { useMultiClientUsage } from "./MultiClientUsage";
import { modelUsageColor } from "../components/modelUsagePresentation";

export interface ClaudeRuntimeAgent {
  id: string; client: string; parentId: string | null; phase: string; model: string | null;
  lastActivity: string; liveOutputTps: number; liveTotalTps: number; recentSpeed: number | null;
}
export interface ClaudeRuntimeSnapshot {
  enabled: boolean; capturedAt: string | null; sourceAvailable: Record<string, boolean>;
  liveOutputTps: number; liveTotalTps: number; estimatedShare: number;
  modelRates: { client: string; model: string; outputTps: number; totalTps: number; generatingAgents: number; toolsAgents: number }[];
  mainAgents: ClaudeRuntimeAgent[]; subagents: ClaudeRuntimeAgent[];
  latestResponse: { client: string; model: string | null; outputTokens: number; totalTokens: number; durationMs: number | null; speed: number | null; endedAt: string } | null;
  configurationIssue: string | null;
}
const empty: ClaudeRuntimeSnapshot = { enabled: false, capturedAt: null, sourceAvailable: {}, liveOutputTps: 0, liveTotalTps: 0, estimatedShare: 0, modelRates: [], mainAgents: [], subagents: [], latestResponse: null, configurationIssue: null };
let cached = empty, pending = false, timer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();
const recent = new Map<string, NonNullable<ClaudeRuntimeSnapshot["latestResponse"]>>();
export function qualifiedClaudeInterval(row: NonNullable<ClaudeRuntimeSnapshot["latestResponse"]>): number | null {
  if (!row.durationMs || row.durationMs <= 400 || !Number.isFinite(row.outputTokens)) return null;
  const tps = row.outputTokens / (row.durationMs / 1000);
  return Number.isFinite(tps) && tps >= 2 && tps <= 500 ? tps : null;
}
export function scopedClaudeEstimateShare(value: number, enabledSources: readonly string[], allowed: readonly string[]): number | null {
  if (!Number.isFinite(value) || value < 0 || value > 1 || !enabledSources.length) return null;
  const selected = new Set(allowed);
  return enabledSources.every(source => selected.has(source)) ? value : null;
}
async function poll() {
  if (pending || !listeners.size) return;
  pending = true;
  try {
    const next = await callCommandStrict<ClaudeRuntimeSnapshot>("read_claude_local_runtime_snapshot");
    // Native command strips all unknown fields and verifies its local helper.
    // A stopped/expired reader cannot leave old activity visible indefinitely.
    const fresh = next.capturedAt && Math.abs(Date.now() - Date.parse(next.capturedAt)) <= 10000;
    cached = next.enabled && fresh ? next : { ...empty, enabled: next.enabled, configurationIssue: next.configurationIssue };
    const response = cached.latestResponse;
    if (response && ["claudeCode", "claudeDesktop"].includes(response.client)) {
      recent.set([response.client, response.model, response.endedAt, response.outputTokens, response.durationMs].join("|"), response);
    }
    for (const [id, row] of recent) if (Date.parse(row.endedAt) < Date.now() - 1800000) recent.delete(id);
    while (recent.size > 1000) recent.delete(recent.keys().next().value!);
  } catch { cached = { ...empty, configurationIssue: "本地 Claude 读取器暂不可用" }; }
  finally {
    pending = false;
    listeners.forEach(listener => listener());
    if (listeners.size) timer = setTimeout(poll, 2000);
  }
}
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (listeners.size === 1 && isTauriRuntimeAvailable()) void poll();
  return () => { listeners.delete(listener); if (!listeners.size) clearTimeout(timer); };
}
export function useClaudeLocalRuntime(allowed: readonly string[], monitoringEnabled = true) {
  const { snapshot } = useMultiClientUsage();
  const enabled = monitoringEnabled && snapshot.preferences.some(p => p.enabled && ["claudeCode", "claudeDesktop"].includes(p.client));
  const subscribeWhenEnabled = useCallback((listener: () => void) => enabled ? subscribe(listener) : () => {}, [enabled]);
  const value = useSyncExternalStore(subscribeWhenEnabled, () => cached, () => empty);
  const selected = new Set(allowed.filter(c => ["claudeCode", "claudeDesktop"].includes(c)));
  const active = (agent: ClaudeRuntimeAgent) => selected.has(agent.client) && ["generating", "tools"].includes(agent.phase)
    && Date.parse(agent.lastActivity) >= Date.now() - 300000;
  const enabledSources = snapshot.preferences.filter(p => p.enabled && ["claudeCode", "claudeDesktop"].includes(p.client));
  const estimatedShareForSelection = scopedClaudeEstimateShare(value.estimatedShare, enabledSources.map(p => p.client), allowed);
  return { ...value, enabled,
    // Upstream's fraction is aggregate-only. Do not apply another client's
    // calibration to a filtered client view.
    estimatedShareForSelection,
    modelRates: enabled ? value.modelRates.filter(r => selected.has(r.client)) : [],
    mainAgents: enabled ? value.mainAgents.filter(active) : [], subagents: enabled ? value.subagents.filter(active) : [],
    rows: enabled ? [...recent.values()].filter(r => selected.has(r.client)).sort((a,b) => Date.parse(b.endedAt) - Date.parse(a.endedAt)) : [],
  };
}

export function ClaudeLocalRuntimePanel({ allowed, compact = false, monitoringEnabled = true }: { allowed: readonly string[]; compact?: boolean; monitoringEnabled?: boolean }) {
  const runtime = useClaudeLocalRuntime(allowed, monitoringEnabled);
  if (!allowed.some(c => ["claudeCode", "claudeDesktop"].includes(c))) return null;
  const qualified = runtime.rows.filter(row => qualifiedClaudeInterval(row) !== null);
  const models = [...new Set(qualified.map(row => row.model ?? "unknown"))].sort();
  const mean = (model: string, minutes: number) => {
    const rows = qualified.filter(r => r.model === model && Date.parse(r.endedAt) >= Date.now() - minutes * 60000);
    const duration = rows.reduce((n,r) => n + (r.durationMs ?? 0), 0);
    return duration ? (rows.reduce((n,r) => n + r.outputTokens, 0) * 1000 / duration).toFixed(1) : "—";
  };
  return <div className="claude-local-runtime" style={{ fontSize: compact ? 10 : 12, paddingBlock: compact ? 3 : 8 }}>
    <strong>Claude · 请求区间 TPS</strong>
    {!compact && runtime.modelRates.some(r => r.outputTps > 0) && runtime.estimatedShareForSelection !== null && <div><small title="沿用 Agent Speed 的请求时间线分类，并非逐字流式实测">活动曲线 · 估算占比 {(runtime.estimatedShareForSelection * 100).toFixed(0)}%</small></div>}
    {!runtime.enabled ? <p>本地读取已关闭</p> : !models.length ? <p className="qs-muted">{(runtime.configurationIssue ? "本地读取器暂不可用" : "等待本地输出记录")}</p> :
      <table style={{ width: "100%", fontVariantNumeric: "tabular-nums" }}><thead><tr><th>模型</th><th>最新</th>{!compact && <><th>5分钟</th><th>15分钟</th><th>30分钟</th></>}</tr></thead><tbody>{models.map(model => <tr key={model}>
        <td style={{ color: modelUsageColor(model), textAlign: "left" }}>{model.replace("claude-", "")}</td>
        <td>{qualifiedClaudeInterval(qualified.find(r => (r.model ?? "unknown") === model)!)?.toFixed(1)}</td>
        {!compact && <><td>{mean(model, 5)}</td><td>{mean(model, 15)}</td><td>{mean(model, 30)}</td></>}
      </tr>)}</tbody></table>}
    {!compact && <>{qualified.length > 0 && <ClaudeIntervalTrend rows={qualified}/>}
      <small>本次运行采样 · 本地请求区间估算；与 Codex 正文 TPS 分开计算。</small>
      {runtime.rows.slice(0,6).map(row => <div key={[row.client,row.endedAt,row.outputTokens].join(":")} style={{display:"flex",gap:8,paddingBlock:3}}>
        <time>{new Date(row.endedAt).toLocaleTimeString()}</time><span>{row.model}</span><span style={{marginLeft:"auto"}}>{row.outputTokens} Token · {row.durationMs === null ? "无时长" : (row.durationMs/1000).toFixed(2)+"s"} · {qualifiedClaudeInterval(row)?.toFixed(1) ?? "低置信度"}</span>
      </div>)}</>}
  </div>;
}

export function ClaudeLocalTasks({ allowed }: { allowed: readonly string[] }) {
  const runtime = useClaudeLocalRuntime(allowed);
  if (!allowed.some(c => ["claudeCode", "claudeDesktop"].includes(c))) return null;
  return <section style={{fontSize:12,paddingBlock:8}}>
    <strong>Claude · {runtime.mainAgents.length} 主任务 · {runtime.subagents.length} 子 Agent</strong>
    {runtime.mainAgents.map(agent => <div key={agent.id} style={{paddingBlock:6}}>
      <span style={{color:modelUsageColor(agent.model ?? "unknown")}}>{agent.model ?? "未知模型"}</span> · {agent.phase === "tools" ? "工具执行中" : "生成中"} · {agent.id.slice(-8)}
      {runtime.subagents.filter(child => child.parentId === agent.id).map(child => <div key={child.id} style={{paddingLeft:12,paddingTop:4}}>↳ {child.model ?? "未知模型"} · {child.phase === "tools" ? "工具执行中" : "生成中"} · {child.id.slice(-8)}</div>)}
    </div>)}
    {runtime.subagents.filter(child => !runtime.mainAgents.some(main => main.id === child.parentId)).map(child => <p key={child.id}>子 Agent · {child.model ?? "未知模型"} · {child.id.slice(-8)}</p>)}
    {!runtime.capturedAt && <p className="qs-muted">等待本地活动记录；不会请求 Claude 接口。</p>}
  </section>;
}

function ClaudeIntervalTrend({ rows }: { rows: NonNullable<ClaudeRuntimeSnapshot["latestResponse"]>[] }) {
  const first = Math.floor((Date.now()/1000 - 1800)/300)*300;
  const groups = new Map<string, Map<number, [number,number]>>();
  for (const row of rows) {
    if (qualifiedClaudeInterval(row) === null) continue;
    const time = Math.floor(Date.parse(row.endedAt)/300000)*300;
    const model = row.model ?? "unknown", buckets = groups.get(model) ?? new Map<number,[number,number]>();
    const prior = buckets.get(time) ?? [0,0];
    buckets.set(time, [prior[0]+row.outputTokens, prior[1]+(row.durationMs ?? 0)/1000]); groups.set(model,buckets);
  }
  const series = [...groups].map(([model,buckets]) => ({model,points:[...buckets].sort(([a],[b])=>a-b).map(([time,[tokens,duration]])=>({time,tps:tokens/duration}))}));
  const maximum = Math.max(1,...series.flatMap(s=>s.points.map(p=>p.tps)));
  return <div style={{paddingBlock:8}}><small>近半小时 · 每 5 分钟按 Token / 耗时加权</small>
    <svg viewBox="0 0 360 110" role="img" aria-label="Claude 请求区间速度，每5分钟加权均值" style={{width:"100%",height:110,display:"block"}}>
      <path d="M12 5V94H350" stroke="currentColor" opacity=".25" fill="none"/>
      {series.map(series => {
        let prior = 0;
        const d = series.points.map(p => {
          const command = p.time - prior === 300 ? "L" : "M"; prior=p.time;
          return `${command}${12 + Math.min(1,Math.max(0,(p.time-first)/1800))*338},${94-p.tps/maximum*80}`;
        }).join(" ");
        return <g key={series.model} fill={modelUsageColor(series.model)}><path d={d} fill="none" stroke={modelUsageColor(series.model)} strokeWidth="1.7"/>
          {series.points.map(p=><circle key={p.time} cx={12+Math.min(1,Math.max(0,(p.time-first)/1800))*338} cy={94-p.tps/maximum*80} r="2.5"><title>{series.model} · {new Date(p.time*1000).toLocaleTimeString()} · {p.tps.toFixed(1)} TPS</title></circle>)}
        </g>;
      })}
      <text x="12" y="108" fill="currentColor" fontSize="9">30 分钟前</text><text x="330" y="108" fill="currentColor" fontSize="9">现在</text>
    </svg>
  </div>;
}
