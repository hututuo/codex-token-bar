import { floatingModelUsageKey } from "../components/modelUsagePresentation";
import { useSyncExternalStore, useState } from "react";
import { callCommandStrict } from "../api/command";
import { desktopPlatform } from "../platform/desktop";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { listen } from "@tauri-apps/api/event";

export type ActivitySpeedMode = "bar" | "agentSpeed";
const key = "activitySpeed.displayMode.v1";
let current: ActivitySpeedMode = "bar";
const listeners = new Set<() => void>();
let unlisten: (() => void) | undefined;
let generation = 0;
let revision = 0;
export const normalizeActivitySpeedMode = (raw: unknown): ActivitySpeedMode => raw === "agentSpeed" ? "agentSpeed" : "bar";
function apply(raw: unknown) {
  revision++;
  const next = normalizeActivitySpeedMode(raw);
  if (current === next) return;
  current = next; listeners.forEach(listener => listener());
}
function subscribe(listener: () => void) {
  listeners.add(listener);
  if (listeners.size === 1) {
    const token = ++generation;
    const initialRevision = revision;
    if (isTauriRuntimeAvailable()) {
      void callCommandStrict<string>("read_activity_speed_mode").then(value => { if (generation === token && revision === initialRevision) apply(value); }).catch(() => {});
      void Promise.allSettled([
        desktopPlatform.onAppSettingsChanged(value => apply(value.displaySurfaces.speedDisplayMode)),
        listen<string>("activity-speed-mode-changed", event => apply(event.payload)),
      ]).then(results => {
        const stops = results.flatMap(result => result.status === "fulfilled" ? [result.value] : []);
        const stop = () => stops.forEach(fn => fn());
        if (generation === token) unlisten = stop; else stop();
      });
    } else if (typeof localStorage !== "undefined") apply(localStorage.getItem(key));
  }
  return () => { listeners.delete(listener); if (!listeners.size) { generation++; unlisten?.(); unlisten = undefined; } };
}
export function useActivitySpeedMode() {
  return useSyncExternalStore(subscribe, () => current, () => "bar" as const);
}
export async function saveActivitySpeedMode(raw: unknown) {
  const mode = normalizeActivitySpeedMode(raw);
  if (isTauriRuntimeAvailable()) {
    const saved = await callCommandStrict<string>("save_activity_speed_mode", { mode });
    apply(saved);
  } else {
    if (typeof localStorage !== "undefined") localStorage.setItem(key, mode);
    apply(mode);
  }
}
export function ActivitySpeedModePicker() {
  const mode = useActivitySpeedMode();
  const [saving, setSaving] = useState(false), [error,setError] = useState("");
  return <div><div className="activity-speed-choice" style={{display:"flex",gap:4,padding:3,borderRadius:9,background:"rgba(128,128,128,.12)",width:"fit-content",marginBlock:6}} role="group" aria-label="速度显示算法">
    {(["bar","agentSpeed"] as const).map(value => <button key={value} disabled={saving} aria-pressed={mode===value}
      style={{fontSize:11,padding:"5px 10px",borderRadius:7,border:"none",color:"inherit",background:mode===value?"rgba(88,145,212,.26)":"transparent"}} className={mode===value ? "active" : ""} onClick={() => {setSaving(true);setError("");void saveActivitySpeedMode(value).catch(()=>setError("设置未保存，请重试")).finally(()=>setSaving(false));}}>
      {value==="bar" ? "Bar 模式" : "Agent Speed"}</button>)}
    </div>{error && <small role="status">{error}</small>}</div>;
}
export interface ActivityModelRate { model: string; tokensPerSecond: number }
export function selectedActivityRates(codex: readonly ActivityModelRate[], upstream: readonly {client:string;model:string;outputTps:number}[], allowed: readonly string[], mode: ActivitySpeedMode, codexOutputRate?: number): ActivityModelRate[] {
  const sums = new Map<string,number>();
  const add=(model:string,rate:number)=>{ if (Number.isFinite(rate)&&rate>1e-9) { const key=floatingModelUsageKey(model.trim()||"unknown"); sums.set(key,(sums.get(key)??0)+rate); } };
  if (mode==="bar" && allowed.includes("codex")) {
    const valid=codex.filter(row=>Number.isFinite(row.tokensPerSecond)&&row.tokensPerSecond>0);
    const known=valid.reduce((sum,row)=>sum+row.tokensPerSecond,0);
    const total=codexOutputRate===undefined ? known : Number.isFinite(codexOutputRate) ? Math.max(0,codexOutputRate) : 0;
    const scale=known>total ? total/known : 1;
    for(const row of valid)add(row.model,row.tokensPerSecond*scale);
    if(total>known)add("unknown",total-known);
  }
  for (const row of upstream) if (allowed.includes(row.client) && (row.client!=="codex" || mode==="agentSpeed")) add(row.model,row.outputTps);
  return [...sums].sort(([a],[b])=>a.localeCompare(b)).map(([model,tokensPerSecond])=>({model,tokensPerSecond}));
}
