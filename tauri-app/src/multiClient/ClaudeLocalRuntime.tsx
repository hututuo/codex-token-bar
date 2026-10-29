import type {CodexHomeSourceToken} from "../types/platform";
import { useCallback, useSyncExternalStore, useEffect, useState, useMemo } from "react";
import { useActivitySpeedMode, selectedActivityRates, type ActivityModelRate } from "./activitySpeedMode";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { useMultiClientUsage } from "./MultiClientUsage";
import { ActivitySpeedHistoryPlot } from "./ActivitySpeedHistoryPlot";
import {useDocumentVisible} from "../components/useDocumentVisible";
import {ActivityRateUnitControl,useActivityRatePreferences} from "../components/liveRate/ActivityRateUnits";
import {activityRateText,activityRateValue} from "../components/liveRate/activityRatePresentation";
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
export function useClaudeLocalRuntime(allowed: readonly string[], monitoringEnabled = true, includeAgentSpeedCodex = false) {
  const { snapshot } = useMultiClientUsage();
  const mode = useActivitySpeedMode();
  const enabled = monitoringEnabled && (includeAgentSpeedCodex || mode === "agentSpeed" || snapshot.preferences.some(p => p.enabled && ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode"].includes(p.client)));
  const subscribeWhenEnabled = useCallback((listener: () => void) => enabled ? subscribe(listener) : () => {}, [enabled]);
  const value = useSyncExternalStore(subscribeWhenEnabled, () => cached, () => empty);
  const selected = new Set(allowed.filter(c => ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode"].includes(c) || (c === "codex" && (includeAgentSpeedCodex || mode === "agentSpeed"))));
  const active = (agent: ClaudeRuntimeAgent) => selected.has(agent.client) && ["generating", "tools"].includes(agent.phase)
    && Date.parse(agent.lastActivity) >= Date.now() - 300000;
  const enabledSources = snapshot.preferences.filter(p => p.enabled);
  const estimatedShareForSelection = scopedClaudeEstimateShare(value.estimatedShare, enabledSources.map(p => p.client), allowed);
  return { ...value, enabled, configuredClients: snapshot.preferences.filter(p=>p.enabled).map(p=>p.client), sourceSelectionKey: JSON.stringify(snapshot.preferences.map(p=>[p.client,p.enabled,p.path])),
    // Upstream's fraction is aggregate-only. Do not apply another client's
    // calibration to a filtered client view.
    estimatedShareForSelection,
    modelRates: enabled ? value.modelRates.filter(r => selected.has(r.client)) : [],
    mainAgents: enabled ? value.mainAgents.filter(a => ["claudeCode", "claudeDesktop"].includes(a.client) && active(a)) : [], subagents: enabled ? value.subagents.filter(a => ["claudeCode", "claudeDesktop"].includes(a.client) && active(a)) : [],
    rows: enabled ? [...recent.values()].filter(r => selected.has(r.client)).sort((a,b) => Date.parse(b.endedAt) - Date.parse(a.endedAt)) : [],
  };
}

interface Aggregate { weightedOutput:number; coveredSeconds:number }
interface ActivitySeries { dimensions:{displayMode:string;client:string;model:string;estimatorId?:string}; rolling5m:Aggregate|null;rolling15m:Aggregate|null;rolling30m:Aggregate|null;fiveMinuteTrend:{bucketStart:number;value:Aggregate}[];halfMinuteTrend?:{bucketStart:number;value:Aggregate}[] }
export function ClientActivitySpeedPanel({ allowed, sourceToken = null, compact = false, monitoringEnabled = true, codexRates = [], codexAvailable = false, codexOutputRate }: { allowed: readonly string[]; sourceToken?: CodexHomeSourceToken | null; compact?: boolean; monitoringEnabled?: boolean; codexRates?: readonly ActivityModelRate[]; codexAvailable?: boolean; codexOutputRate?: number }) {
  const runtime = useClaudeLocalRuntime(allowed, monitoringEnabled, true), mode="agentSpeed";
  const [history,setHistory]=useState<ActivitySeries[]>([]),[issue,setIssue]=useState("");
  const sourceKey=JSON.stringify([sourceToken,runtime.sourceSelectionKey]);
  const [historyKey,setHistoryKey]=useState("");
  const [asOf,setAsOf]=useState(Date.now()/1000),[windowSeconds,setWindowSeconds]=useState(43200);
  const visible=useDocumentVisible(),{unit,fx}=useActivityRatePreferences();
  const rates=selectedActivityRates([],runtime.modelRates,allowed,mode);
  useEffect(()=>{
    if(compact||!monitoringEnabled||!visible||!isTauriRuntimeAvailable())return;
    let alive=true, timer:ReturnType<typeof setTimeout>;
    const refresh=async()=>{try{const result=await callCommandStrict<{series:ActivitySeries[]}>("read_activity_speed_history",{windowSeconds:86400});if(alive){setHistory(result.series);setHistoryKey(sourceKey);setAsOf(Date.now()/1000);setIssue("");}}catch{if(alive)setIssue("活动速度索引暂不可用");}finally{if(alive)timer=setTimeout(refresh,60000);}};
    void refresh();return()=>{alive=false;clearTimeout(timer);};
  },[compact,monitoringEnabled,mode,visible,sourceKey]);
  const hasCoverage=monitoringEnabled&&allowed.some(client=>runtime.sourceAvailable[client]);
  const allowedKey=allowed.join("|"), configuredKey=runtime.configuredClients.join("|");
  const groups=useMemo(()=>{
    const rows=historyKey===sourceKey?history.filter(s=>s.dimensions.displayMode===mode&&allowed.includes(s.dimensions.client)&&(s.halfMinuteTrend?.length??0)>0):[];
    const clients=[...rows.map(row=>row.dimensions.client),...allowed.filter(client=>client==="codex"||runtime.configuredClients.includes(client as typeof runtime.configuredClients[number]))];
    return [...new Set(clients)].sort().map(client=>({client,rows:rows.filter(row=>row.dimensions.client===client)}));
  },[history,historyKey,sourceKey,mode,allowedKey,configuredKey]);
  const hasHistory=groups.length>0;
  return <div className="client-activity-speed" style={{fontSize:compact?10:12,paddingBlock:compact?3:8}}>
    <div style={{display:"flex",alignItems:"center",justifyContent:"space-between"}}><strong>活动速率 · Agent Speed</strong><strong>{hasCoverage?activityRateText(activityRateValue(rates.reduce((n,r)=>n+r.tokensPerSecond,0),rates,unit,fx),unit)+" "+unit:"—"}</strong></div>
    {!compact&&<><div className="activity-speed-history-controls"><span style={{fontSize:10,opacity:.75}}>Agent Speed 本地活动速率</span><ActivityRateUnitControl/></div>
      <div className="activity-speed-history-ranges">{[43200,86400].map(seconds=><button key={seconds} type="button" aria-pressed={windowSeconds===seconds} onClick={()=>setWindowSeconds(seconds)}>{seconds===43200?"12小时":"24小时"}</button>)}</div></>}
    {!rates.length&&!hasHistory&&<p className="qs-muted">{monitoringEnabled?"等待本地活动记录":"本地读取已关闭"}</p>}
    {!compact&&groups.map(({client,rows})=><div key={client} style={{paddingTop:10}}>
      <strong>{client==="codex"?"Codex":client==="claudeCode"?"Claude CLI":client==="claudeDesktop"?"Claude Desktop":client}</strong>
      <ActivitySpeedHistoryPlot rows={rows} asOf={asOf} windowSeconds={windowSeconds} unit={unit} fx={fx}/>
    </div>)}
    {!compact&&<small>{issue||"每30秒平均速率 · 无活动采样的时段留空"}</small>}
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
