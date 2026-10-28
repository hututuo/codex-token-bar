import { useCallback, useSyncExternalStore, useEffect, useState, useId } from "react";
import { useActivitySpeedMode, ActivitySpeedModePicker, selectedActivityRates, type ActivityModelRate } from "./activitySpeedMode";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { useMultiClientUsage } from "./MultiClientUsage";
import { activityChartPoints } from "./activitySpeedChart";
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
  const mode = useActivitySpeedMode();
  const enabled = monitoringEnabled && (mode === "agentSpeed" || snapshot.preferences.some(p => p.enabled && ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode"].includes(p.client)));
  const subscribeWhenEnabled = useCallback((listener: () => void) => enabled ? subscribe(listener) : () => {}, [enabled]);
  const value = useSyncExternalStore(subscribeWhenEnabled, () => cached, () => empty);
  const selected = new Set(allowed.filter(c => ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode"].includes(c) || (c === "codex" && mode === "agentSpeed")));
  const active = (agent: ClaudeRuntimeAgent) => selected.has(agent.client) && ["generating", "tools"].includes(agent.phase)
    && Date.parse(agent.lastActivity) >= Date.now() - 300000;
  const enabledSources = snapshot.preferences.filter(p => p.enabled);
  const estimatedShareForSelection = scopedClaudeEstimateShare(value.estimatedShare, enabledSources.map(p => p.client), allowed);
  return { ...value, enabled,
    // Upstream's fraction is aggregate-only. Do not apply another client's
    // calibration to a filtered client view.
    estimatedShareForSelection,
    modelRates: enabled ? value.modelRates.filter(r => selected.has(r.client)) : [],
    mainAgents: enabled ? value.mainAgents.filter(a => ["claudeCode", "claudeDesktop"].includes(a.client) && active(a)) : [], subagents: enabled ? value.subagents.filter(a => ["claudeCode", "claudeDesktop"].includes(a.client) && active(a)) : [],
    rows: enabled ? [...recent.values()].filter(r => selected.has(r.client)).sort((a,b) => Date.parse(b.endedAt) - Date.parse(a.endedAt)) : [],
  };
}

interface Aggregate { weightedOutput:number; coveredSeconds:number }
interface ActivitySeries { dimensions:{displayMode:string;client:string;model:string;estimatorId?:string}; rolling5m:Aggregate|null;rolling15m:Aggregate|null;rolling30m:Aggregate|null;fiveMinuteTrend:{bucketStart:number;value:Aggregate}[];oneMinuteTrend?:{bucketStart:number;value:Aggregate}[] }
export function ClientActivitySpeedPanel({ allowed, compact = false, monitoringEnabled = true, codexRates = [], codexAvailable = false, codexOutputRate }: { allowed: readonly string[]; compact?: boolean; monitoringEnabled?: boolean; codexRates?: readonly ActivityModelRate[]; codexAvailable?: boolean; codexOutputRate?: number }) {
  const runtime = useClaudeLocalRuntime(allowed, monitoringEnabled), mode=useActivitySpeedMode();
  const [history,setHistory]=useState<ActivitySeries[]>([]),[issue,setIssue]=useState("");
  const rates=selectedActivityRates(codexRates,runtime.modelRates,allowed,mode,codexOutputRate);
  useEffect(()=>{
    if(compact||!monitoringEnabled||!isTauriRuntimeAvailable())return;
    let alive=true, timer:ReturnType<typeof setTimeout>;
    const refresh=async()=>{try{const result=await callCommandStrict<{series:ActivitySeries[]}>("read_activity_speed_history");if(alive){setHistory(result.series);setIssue("");}}catch{if(alive)setIssue("活动速度索引暂不可用");}finally{if(alive)timer=setTimeout(refresh,10000);}};
    void refresh();return()=>{alive=false;clearTimeout(timer);};
  },[compact,monitoringEnabled,mode]);
  const hasCoverage=monitoringEnabled&&allowed.some(client=>client==="codex"&&mode==="bar"?codexAvailable:runtime.sourceAvailable[client]);
  const rows=history.filter(s=>s.dimensions.displayMode===mode&&allowed.includes(s.dimensions.client)&&(s.oneMinuteTrend?.length??0)>0);
  return <div className="client-activity-speed" style={{fontSize:compact?10:12,paddingBlock:compact?3:8}}>
    <div style={{display:"flex",alignItems:"center",justifyContent:"space-between"}}><strong>聚合活动速度</strong><strong>{hasCoverage?rates.reduce((n,r)=>n+r.tokensPerSecond,0).toFixed(1)+" t/s":"—"}</strong></div>
    {!compact&&<ActivitySpeedModePicker/>}
    {!rates.length&&!rows.length&&<p className="qs-muted">{monitoringEnabled?"等待本地活动记录":"本地读取已关闭"}</p>}
    {!compact&&[...new Set(rows.map(row=>row.dimensions.client))].sort().map(client=><div key={client} style={{paddingTop:10}}>
      <strong>{client==="codex"?"Codex":client==="claudeCode"?"Claude CLI":client==="claudeDesktop"?"Claude Desktop":client}</strong>
      <ActivityTrend rows={rows.filter(row=>row.dimensions.client===client)}/>
      <div style={{display:"flex",gap:12,flexWrap:"wrap"}}>{rows.filter(row=>row.dimensions.client===client).map(row=><small key={row.dimensions.model} style={{color:modelUsageColor(row.dimensions.model)}}>{row.dimensions.model.replace(/^gpt-/i,"")}</small>)}</div>
    </div>)}
    {!compact&&<small>{issue||"近半小时 · 每分钟加权速度 · 空缺表示无活动采样"}</small>}
  </div>;
}
function ActivityTrend({rows}:{rows:ActivitySeries[]}){
  const now=Date.now()/1000, start=now-1800, clipId=useId();
  const plotted=rows.map(row=>({row,points:activityChartPoints(row.oneMinuteTrend??[],now)}));
  const maximum=Math.max(1,...plotted.flatMap(series=>series.points.map(p=>p.rate)));
  const x=(stamp:number)=>32+(stamp-start)/1800*650, y=(rate:number)=>122-rate/maximum*104;
  return <svg viewBox="0 0 720 150" aria-label="近半小时活动速度，每分钟一个点" role="img" style={{width:"100%",height:150,display:"block"}}>
    <defs><clipPath id={clipId}><rect x="32" y="12" width="650" height="110"/></clipPath></defs>
    <path d="M32 12V122H682" fill="none" stroke="currentColor" opacity=".25"/>
    {[0,1,2,3,4,5,6].map(tick=>{const stamp=start+tick*300;return <g key={tick}><path d={`M${x(stamp)} 12V122`} stroke="currentColor" opacity=".1"/><text x={x(stamp)} y="143" textAnchor="middle" fontSize="11" fill="currentColor">{new Date(stamp*1000).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"})}</text></g>;})}
    {[0,.5,1].map(fraction=><text key={fraction} x="28" y={y(maximum*fraction)+4} textAnchor="end" fontSize="10" fill="currentColor">{(maximum*fraction).toFixed(0)}</text>)}
    <g clipPath={`url(#${clipId})`}>{plotted.map(({row,points})=>{
      let previous:number|undefined;
      const d=points.map(p=>{const command=previous===p.segment?"L":"M";previous=p.segment;return `${command}${x(p.bucketStart)},${y(p.rate)}`;}).join(" ");
      return <g key={row.dimensions.client+row.dimensions.model}><path d={d} fill="none" stroke={modelUsageColor(row.dimensions.model)} strokeWidth="1.7"/>{points.map(p=><circle key={p.bucketStart} cx={x(p.bucketStart)} cy={y(p.rate)} r="2.5" fill={modelUsageColor(row.dimensions.model)}><title>{row.dimensions.model} · {new Date(p.bucketStart*1000).toLocaleTimeString()} · {p.rate.toFixed(1)} t/s</title></circle>)}</g>;
    })}</g>
  </svg>;
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
