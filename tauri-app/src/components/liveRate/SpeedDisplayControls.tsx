import { localAgentSpeedHistory } from "./speedDisplayHistory";
import { useEffect, useState, useSyncExternalStore } from "react";
import { listen } from "@tauri-apps/api/event";
import { callCommandStrict } from "../../api/command";
import { isTauriRuntimeAvailable } from "../../platform/runtime";
import type { ModelRateContribution } from "../../types/live";
import { modelUsageColor, modelUsageKey, modelUsageLabel } from "../modelUsagePresentation";
import { EMPTY_AGENT_SPEED_DISPLAY, SPEED_PREFERENCES_EVENT, invalidateSpeedColors, projectSpeedDisplay, readSpeedColors, writeSpeedColor,
  type AgentSpeedDisplaySnapshot, type SpeedColorGrouping, type SpeedDisplayMode, type SpeedDisplayPreferences } from "./speedDisplay";

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
  const [colors, setColors] = useState(readSpeedColors);
  useEffect(() => {
    const update = () => setColors({ ...readSpeedColors() });
    window.addEventListener(SPEED_PREFERENCES_EVENT, update); window.addEventListener("storage", update);
    return () => { window.removeEventListener(SPEED_PREFERENCES_EVENT, update); window.removeEventListener("storage", update); };
  }, []);
  const save = async (mode: SpeedDisplayMode, grouping: SpeedColorGrouping) => {
    if (isTauriRuntimeAvailable()) {
      const saved = await callCommandStrict<SpeedDisplayPreferences>("set_speed_display_preferences", { mode, grouping });
      apply(saved);
    } else { apply({ mode, grouping }); }
  };
  return { ...preferences, colors, save };
}

export function useSpeedDisplaySnapshot<T extends { tokensPerSecond: number; modelRates?: ModelRateContribution[] }>(base: T, enabled: boolean) {
  const preferences = useSpeedDisplayPreferences();
  const [incoming, setIncoming] = useState(EMPTY_AGENT_SPEED_DISPLAY);
  useEffect(() => {
    if (!enabled || preferences.mode !== "agentSpeed" || !isTauriRuntimeAvailable()) { setIncoming(EMPTY_AGENT_SPEED_DISPLAY); return; }
    let cancelled = false, busy = false;
    const refresh = async () => {
      if (busy) return; busy = true;
      try {
        const value = await callCommandStrict<AgentSpeedDisplaySnapshot>("read_agent_speed_display_snapshot", undefined, 1500);
        if (!cancelled) {
          localAgentSpeedHistory.record(Date.now() / 1000, projectSpeedDisplay(base, preferences, value, enabled).modelRates ?? []);
          setIncoming(value);
        }
      } catch { if (!cancelled) { localAgentSpeedHistory.record(Date.now() / 1000, []); setIncoming(EMPTY_AGENT_SPEED_DISPLAY); } }
      finally { busy = false; }
    };
    void refresh(); const timer = setInterval(() => void refresh(), 500);
    return () => { cancelled = true; clearInterval(timer); };
  }, [enabled, preferences.mode]);
  return projectSpeedDisplay(base, preferences, incoming, enabled);
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

export function SpeedColorSettings({ models }: { models: string[] }) {
  const preferences = useSpeedDisplayPreferences();
  const keys = ["client:codex", "client:claudeCode", "client:deepseek", ...new Set([
    "gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "claude-opus-5", "claude-sonnet-4-5", "deepseek-v4-flash", ...models,
  ].map(value => modelUsageKey(value)))];
  return <details className="speed-color-settings"><summary>彩条颜色</summary><div className="speed-color-grid">
    {keys.map(key => <label key={key}><input type="color" aria-label={`${modelUsageLabel(key)}颜色`} value={modelUsageColor(key)} onChange={e => writeSpeedColor(key, e.target.value)}/>
      <span>{modelUsageLabel(key)}</span>{preferences.colors[key] && <button type="button" aria-label={`恢复${modelUsageLabel(key)}默认颜色`} onClick={e => { e.preventDefault(); writeSpeedColor(key, null); }}>恢复</button>}
    </label>)}
  </div></details>;
}
