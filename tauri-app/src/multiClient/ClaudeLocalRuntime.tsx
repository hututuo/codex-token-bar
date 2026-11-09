import type {CodexHomeSourceToken} from "../types/platform";
import { useCallback, useSyncExternalStore, useEffect } from "react";
import { useActivitySpeedMode, type ActivityModelRate } from "./activitySpeedMode";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { useMultiClientUsage } from "./MultiClientUsage";
import {ActivitySpeedLivePlot} from "./ActivitySpeedLivePlot";
import {ActivityLiveHistory} from "./activityLiveHistory";
import {ActivityModelRateSmoother,claudeBarAgentActive} from "./activityRateSmoothing";
import {ActivityRateUnitControl,useActivityRatePreferences} from "../components/liveRate/ActivityRateUnits";
import { normalizedModelRates } from "../components/liveRate/modelRatePresentation";

export interface ClaudeRuntimeAgent {
  id: string; client: string; parentId: string | null; phase: string; model: string | null;
  title?: string | null; displayStopped?: boolean;
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
const activityLiveHistory = new ActivityLiveHistory();
const barActivityLiveHistory = new ActivityLiveHistory();
const claudeBarActivityLiveHistory = new ActivityLiveHistory();
const claudeBarSmoothers = new Map<string, ActivityModelRateSmoother>();
let barModelRates: ClaudeRuntimeSnapshot['modelRates'] = [];
let barSourceSelectionKey: string | undefined;
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
    barModelRates = cached.modelRates.filter(row => !["claudeCode","claudeDesktop"].includes(row.client));
    for (const client of ["claudeCode","claudeDesktop"]) {
      let smoother = claudeBarSmoothers.get(client);
      if (!smoother) { smoother = new ActivityModelRateSmoother(); claudeBarSmoothers.set(client,smoother); }
      const time = Date.parse(cached.capturedAt ?? '') / 1000;
      const active = fresh && Math.abs(Date.now()/1000-time)<=3 && cached.enabled && cached.sourceAvailable[client] && [...cached.mainAgents,...cached.subagents].some(agent =>
        agent.client === client && claudeBarAgentActive(agent,time));
      const sourceRows = cached.modelRates.filter(row => row.client === client);
      const raw = new Map<string,number>();
      for (const row of sourceRows) raw.set(row.model,(raw.get(row.model) ?? 0)+row.outputTps);
      for (const [model,outputTps] of smoother.update(raw,time,!!active)) {
        const row = sourceRows.find(row => row.model === model);
        barModelRates.push({client,model,outputTps,totalTps:row?.totalTps ?? 0,generatingAgents:row?.generatingAgents ?? 0,toolsAgents:row?.toolsAgents ?? 0});
      }
    }
    if (fresh && cached.enabled) activityLiveHistory.record(Date.parse(cached.capturedAt!) / 1000, cached.sourceAvailable, cached.modelRates);
    else if (!next.enabled) activityLiveHistory.clear();
    if (fresh && cached.enabled) claudeBarActivityLiveHistory.record(Date.parse(cached.capturedAt!) / 1000, cached.sourceAvailable, barModelRates.filter(row => ["claudeCode","claudeDesktop"].includes(row.client)));
    else if (!next.enabled) claudeBarActivityLiveHistory.clear();
    const response = cached.latestResponse;
    if (response && ["claudeCode", "claudeDesktop"].includes(response.client)) {
      recent.set([response.client, response.model, response.endedAt, response.outputTokens, response.durationMs].join("|"), response);
    }
    for (const [id, row] of recent) if (Date.parse(row.endedAt) < Date.now() - 1800000) recent.delete(id);
    while (recent.size > 1000) recent.delete(recent.keys().next().value!);
  } catch { cached = { ...empty, configurationIssue: "本地 Claude 读取器暂不可用" }; barModelRates=[]; claudeBarSmoothers.clear(); }
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
  const enabled = monitoringEnabled && (includeAgentSpeedCodex || mode === "agentSpeed" || snapshot.preferences.some(p => p.enabled && ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode", "antigravity"].includes(p.client)));
  const subscribeWhenEnabled = useCallback((listener: () => void) => enabled ? subscribe(listener) : () => {}, [enabled]);
  const value = useSyncExternalStore(subscribeWhenEnabled, () => cached, () => empty);
  const selected = new Set(allowed.filter(c => ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode", "antigravity"].includes(c) || (c === "codex" && (includeAgentSpeedCodex || mode === "agentSpeed"))));
  const active = (agent: ClaudeRuntimeAgent) => selected.has(agent.client) && !agent.displayStopped && ["generating", "tools"].includes(agent.phase)
    && Date.parse(agent.lastActivity) >= Date.now() - 300000 && Date.parse(agent.lastActivity) <= Date.now() + 5000;
  const sourceSelectionKey = JSON.stringify(snapshot.preferences.map(p=>[p.client,p.enabled,p.path]));
  useEffect(()=>{
    activityLiveHistory.selectSource(sourceSelectionKey);
    claudeBarActivityLiveHistory.selectSource(sourceSelectionKey);
    if (barSourceSelectionKey !== sourceSelectionKey) {
      barSourceSelectionKey=sourceSelectionKey; claudeBarSmoothers.clear(); barModelRates=[];
    }
  },[sourceSelectionKey]);
  const enabledSources = snapshot.preferences.filter(p => p.enabled);
  const estimatedShareForSelection = scopedClaudeEstimateShare(value.estimatedShare, enabledSources.map(p => p.client), allowed);
  const activitySeries = activityLiveHistory.snapshot(Date.now()/1000, allowed);
  const displaySeries = mode === "bar" ? [...activitySeries.filter(row => !["claudeCode","claudeDesktop"].includes(row.client)),...claudeBarActivityLiveHistory.snapshot(Date.now()/1000,allowed)] : activitySeries;
  return { ...value, enabled, configuredClients: snapshot.preferences.filter(p=>p.enabled).map(p=>p.client), sourceSelectionKey, activitySeries: displaySeries,
    // Upstream's fraction is aggregate-only. Do not apply another client's
    // calibration to a filtered client view.
    estimatedShareForSelection,
    modelRates: enabled ? (mode === "bar" ? barModelRates : value.modelRates).filter(r => selected.has(r.client)) : [],
    mainAgents: enabled ? value.mainAgents.filter(a => ["claudeCode", "claudeDesktop", "antigravity"].includes(a.client) && active(a)) : [], subagents: enabled ? value.subagents.filter(a => ["claudeCode", "claudeDesktop", "antigravity"].includes(a.client) && active(a)) : [],
    rows: enabled ? [...recent.values()].filter(r => selected.has(r.client)).sort((a,b) => Date.parse(b.endedAt) - Date.parse(a.endedAt)) : [],
  };
}

export function ClientActivitySpeedPanel({ allowed, sourceToken = null, compact = false, monitoringEnabled = true, codexRates = [], codexOutputRate, codexAvailable = false, onOpen }: { onOpen?:()=>void; allowed: readonly string[]; sourceToken?: CodexHomeSourceToken | null; compact?: boolean; monitoringEnabled?: boolean; codexRates?: readonly ActivityModelRate[]; codexAvailable?: boolean; codexOutputRate?: number }) {
  const runtime = useClaudeLocalRuntime(allowed, monitoringEnabled, true);
  const {unit,fx}=useActivityRatePreferences(),mode=useActivitySpeedMode();
  const sourceKey=JSON.stringify(sourceToken);
  useEffect(()=>barActivityLiveHistory.selectSource(sourceKey),[sourceKey]);
  useEffect(()=>{
    if(!monitoringEnabled){barActivityLiveHistory.clear();return;}
    if(mode!=="bar"||!allowed.includes("codex"))return;
    const rates=normalizedModelRates(codexRates,codexOutputRate).map(r=>({client:"codex",model:r.model,outputTps:r.tokensPerSecond}));
    barActivityLiveHistory.record(Date.now()/1000,{codex:codexAvailable},rates);
  },[monitoringEnabled,mode,codexRates,codexOutputRate,codexAvailable,sourceKey]);
  const rows=mode==="bar"?[...barActivityLiveHistory.snapshot(Date.now()/1000,allowed),...runtime.activitySeries.filter(row=>row.client!=="codex")]:runtime.activitySeries;
  return <div className="client-activity-speed">
    {!compact&&<div className="activity-live-controls"><span>{mode==="bar"&&allowed.includes("codex")?"Bar 活动速率":"Agent Speed"} · 仅保留内存中的近3分钟</span><ActivityRateUnitControl/></div>}
    <ActivitySpeedLivePlot rows={monitoringEnabled?rows:[]} asOf={Date.now()/1000} compact={compact} onOpen={onOpen} unit={unit} fx={fx} modeLabel={mode==="bar"&&allowed.includes("codex")?"Bar 活动速率":"Agent Speed"}/>
  </div>;
}
