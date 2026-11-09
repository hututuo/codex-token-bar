import { useActivitySpeedMode, saveActivitySpeedMode } from "../../multiClient/activitySpeedMode";
import { activityRateSources, liveModelRateSnapshot } from "./modelRatePresentation";
import { SnapshotEpoch } from "../../multiClient/snapshotEpoch";
import { useClaudeLocalRuntime } from "../../multiClient/ClaudeLocalRuntime";
import { useClientScope } from "../../multiClient/useClientScope";
import { localAgentSpeedHistory } from "./speedDisplayHistory";
import { useEffect, useState, useSyncExternalStore } from "react";
import { listen } from "@tauri-apps/api/event";
import { callCommandStrict } from "../../api/command";
import { isTauriRuntimeAvailable } from "../../platform/runtime";
import type { ModelRateContribution } from "../../types/live";
import { SPEED_PREFERENCES_EVENT, invalidateSpeedColors, readSpeedColors,
  type SpeedColorGrouping, type SpeedDisplayMode, type SpeedDisplayPreferences } from "./speedDisplay";

let current: SpeedDisplayPreferences = { mode: "activity", grouping: "model" };
let cleanupPreferences: (()=>void) | undefined;
const preferencesEpoch = new SnapshotEpoch();
const subscribers = new Set<() => void>();
const notify = () => { for (const callback of subscribers) callback(); };
function apply(value: SpeedDisplayPreferences) {
  preferencesEpoch.invalidate();
  current = { mode: value.mode === "agentSpeed" ? "agentSpeed" : "activity", grouping: value.grouping === "client" ? "client" : "model" };
  notify();
}
function initialize() {
  if (cleanupPreferences || typeof window === "undefined") return;
  const storage=()=>{invalidateSpeedColors();notify();};
  let disposed=false,unlisten:(()=>void)|undefined;
  window.addEventListener("storage", storage);
  window.addEventListener(SPEED_PREFERENCES_EVENT, notify);
  cleanupPreferences=()=>{disposed=true;preferencesEpoch.invalidate();unlisten?.();window.removeEventListener("storage",storage);window.removeEventListener(SPEED_PREFERENCES_EVENT,notify);cleanupPreferences=undefined;};
  if (isTauriRuntimeAvailable()) {
    const ticket=preferencesEpoch.capture();
    void listen<SpeedDisplayPreferences>(SPEED_PREFERENCES_EVENT, event => {if(!disposed)apply(event.payload);}).then(stop=>{if(disposed)stop();else unlisten=stop;}).catch(()=>{});
    void callCommandStrict<SpeedDisplayPreferences>("read_speed_display_preferences").then(value=>{if(!disposed&&preferencesEpoch.accepts(ticket))apply(value);}).catch(() => {});
  }
}
function subscribe(callback: () => void) { subscribers.add(callback);initialize(); return () => { subscribers.delete(callback);if(!subscribers.size)cleanupPreferences?.(); }; }
export function useSpeedDisplayPreferences() {
  const preferences = useSyncExternalStore(subscribe, () => current, () => current);
  const activityMode = useActivitySpeedMode();
  const [colors, setColors] = useState(readSpeedColors);
  useEffect(() => {
    const update = () => setColors({ ...readSpeedColors() });
    window.addEventListener(SPEED_PREFERENCES_EVENT, update); window.addEventListener("storage", update);
    return () => { window.removeEventListener(SPEED_PREFERENCES_EVENT, update); window.removeEventListener("storage", update); };
  }, []);
  const save = async (mode: SpeedDisplayMode, grouping: SpeedColorGrouping) => {
    if (isTauriRuntimeAvailable()) {
      const saved = await callCommandStrict<SpeedDisplayPreferences>("set_speed_display_preferences", { mode, grouping });
      await saveActivitySpeedMode(mode === "agentSpeed" ? "agentSpeed" : "bar");
      apply(saved);
    } else { await saveActivitySpeedMode(mode === "agentSpeed" ? "agentSpeed" : "bar"); apply({ mode, grouping }); }
  };
  return { ...preferences, mode: activityMode === "agentSpeed" ? "agentSpeed" as const : "activity" as const, colors, save };
}

export function useLiveModelRateSnapshot(base: { tokensPerSecond: number; modelRates?: ModelRateContribution[]; liveRateAvailable?: boolean },
  enabled: boolean, allowed: readonly string[], sourceKey = "") {
  const preferences = useSpeedDisplayPreferences();
  const local = useClaudeLocalRuntime(allowed, enabled);
  const observedAt = Date.parse(local.capturedAt ?? ""), age = Date.now() - observedAt;
  const fresh = Number.isFinite(age) && age >= -2000 && age <= 3000;
  const mode = preferences.mode === "agentSpeed" ? "agentSpeed" : "bar";
  const sources = activityRateSources(base.modelRates ?? [], local.modelRates, allowed, mode, base.tokensPerSecond, {
    sourceKey: sourceKey + "|" + local.sourceSelectionKey, observedAt: Number.isFinite(observedAt) ? observedAt / 1000 : 0,
    codexAvailable: base.liveRateAvailable !== false,
    upstreamAvailable: Object.fromEntries(allowed.map(client => [client, fresh && local.sourceAvailable[client] === true])),
  });
  return liveModelRateSnapshot(sources, enabled, mode, preferences.grouping);
}

export function useSpeedDisplaySnapshot<T extends { tokensPerSecond: number; modelRates?: ModelRateContribution[]; liveRateAvailable?: boolean }>(base: T, enabled: boolean, sourceKey = "") {
  const { allowed } = useClientScope();
  const liveRates = useLiveModelRateSnapshot(base, enabled, allowed, sourceKey);
  const value = { ...base, modelRates: liveRates.modelRates, tokensPerSecond: liveRates.total,
    colorRates: liveRates.colorRates, liveRateAvailable: liveRates.available, liveRates,
    speedDisplayMode: liveRates.mode === "agentSpeed" ? "agentSpeed" as const : "activity" as const, speedDisplayStatus: liveRates.status };
  useEffect(() => { if (liveRates.enabled && liveRates.mode === "agentSpeed") localAgentSpeedHistory.record(Date.now()/1000, liveRates.modelRates); }, [liveRates]);
  return value;
}

export function SpeedDisplayControls() {
  const settings = useSpeedDisplayPreferences();
  const [error, setError] = useState<string | null>(null);
  const save = (mode: SpeedDisplayMode, grouping: SpeedColorGrouping) => {
    setError(null); void settings.save(mode, grouping).catch(() => setError("设置未保存，请重试"));
  };
  return <div className="speed-display-controls">
    <label>速度算法 <select aria-label="速度算法" value={settings.mode} onChange={e => save(e.target.value as SpeedDisplayMode, settings.grouping)}>
      <option value="activity">活动估算</option><option value="agentSpeed">榜单口径</option>
    </select></label>
    <label>彩条 <select aria-label="彩条分组" value={settings.grouping} onChange={e => save(settings.mode, e.target.value as SpeedColorGrouping)}>
      <option value="model">按模型</option><option value="client">按客户端</option>
    </select></label>
    {error && <span role="status">{error}</span>}
  </div>;
}
