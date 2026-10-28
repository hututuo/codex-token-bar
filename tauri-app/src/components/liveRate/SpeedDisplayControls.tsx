import { useActivitySpeedMode, saveActivitySpeedMode, selectedActivityRates } from "../../multiClient/activitySpeedMode";
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
let initialized = false;
const subscribers = new Set<() => void>();
const notify = () => { for (const callback of subscribers) callback(); };
function apply(value: SpeedDisplayPreferences) {
  current = { mode: value.mode === "agentSpeed" ? "agentSpeed" : "activity", grouping: value.grouping === "client" ? "client" : "model" };
  notify();
}
function initialize() {
  if (initialized || typeof window === "undefined") return;
  initialized = true;
  window.addEventListener("storage", () => { invalidateSpeedColors(); notify(); });
  window.addEventListener(SPEED_PREFERENCES_EVENT, notify);
  if (isTauriRuntimeAvailable()) {
    void listen<SpeedDisplayPreferences>(SPEED_PREFERENCES_EVENT, event => apply(event.payload));
    void callCommandStrict<SpeedDisplayPreferences>("read_speed_display_preferences").then(apply).catch(() => {});
  }
}
function subscribe(callback: () => void) { initialize(); subscribers.add(callback); return () => { subscribers.delete(callback); }; }
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

export function useSpeedDisplaySnapshot<T extends { tokensPerSecond: number; modelRates?: ModelRateContribution[] }>(base: T, enabled: boolean) {
  const preferences = useSpeedDisplayPreferences();
  const { allowed } = useClientScope();
  const local = useClaudeLocalRuntime(allowed, enabled);
  const rates = selectedActivityRates(base.modelRates ?? [], local.modelRates, allowed,
    preferences.mode === "agentSpeed" ? "agentSpeed" : "bar", base.tokensPerSecond);
  const clients = new Map<string, number>();
  if (preferences.mode === "activity" && allowed.includes("codex") && base.tokensPerSecond > 0)
    clients.set("codex", base.tokensPerSecond);
  for (const row of local.modelRates) if (allowed.includes(row.client) && (row.client !== "codex" || preferences.mode === "agentSpeed"))
    clients.set(row.client, (clients.get(row.client) ?? 0) + row.outputTps);
  const value = { ...base, modelRates: enabled ? rates : [], tokensPerSecond: enabled ? rates.reduce((n,r)=>n+r.tokensPerSecond,0) : 0,
    colorRates: preferences.grouping === "client" ? [...clients].map(([client,tokensPerSecond])=>({model:"client:"+client,tokensPerSecond})) : rates,
    speedDisplayMode: preferences.mode, speedDisplayStatus: "本地活动 · 停止或超时归零" };
  useEffect(() => { if (enabled && preferences.mode === "agentSpeed") localAgentSpeedHistory.record(Date.now()/1000, rates); }, [local, enabled, preferences.mode]);
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
