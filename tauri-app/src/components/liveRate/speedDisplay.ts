import type { ModelRateContribution } from "../../types/live";

export type SpeedDisplayMode = "activity" | "agentSpeed";
export type SpeedColorGrouping = "model" | "client";
export interface SpeedDisplayPreferences { mode: SpeedDisplayMode; grouping: SpeedColorGrouping }
export interface AgentSpeedDisplaySnapshot {
  available: boolean;
  tokensPerSecond: number;
  modelRates: ModelRateContribution[];
  clientRates: ModelRateContribution[];
  status: string;
  updatedAtMs: number;
}
const DISPLAY_STATUS: Record<string, string> = {
  running: "榜单口径 · 本地活动截止", idle: "等待新增输出 · 停止或超时已归零",
  stale: "采集已停更 · 已归零", starting: "正在读取本地客户端日志", noSources: "等待本地客户端日志",
  error: "本地采集暂不可用 · 已归零", unavailable: "等待本地客户端日志", unsupported: "此平台暂不支持", disabled: "实时速率已关闭",
};
export const EMPTY_AGENT_SPEED_DISPLAY: AgentSpeedDisplaySnapshot = {
  available: false, tokensPerSecond: 0, modelRates: [], clientRates: [],
  status: "等待本地客户端日志", updatedAtMs: 0,
};

/** Display projection only. Never used to construct a signed report or update usage totals. */
export function projectSpeedDisplay<T extends { tokensPerSecond: number; modelRates?: ModelRateContribution[] }>(
  base: T, preferences: SpeedDisplayPreferences, incoming: AgentSpeedDisplaySnapshot,
  enabled: boolean, nowMs = Date.now(),
): T & { colorRates: ModelRateContribution[]; speedDisplayMode: SpeedDisplayMode; speedDisplayStatus: string; liveRateAvailable?: boolean } {
  if (preferences.mode === "activity") {
    return { ...base, colorRates: preferences.grouping === "client"
      ? [{ model: "client:codex", tokensPerSecond: enabled ? base.tokensPerSecond : 0 }] : base.modelRates ?? [],
      speedDisplayMode: "activity", speedDisplayStatus: "活动估算" };
  }
  const fresh = enabled && incoming.available && Number.isFinite(incoming.updatedAtMs)
    && nowMs - incoming.updatedAtMs <= 3000 && incoming.updatedAtMs - nowMs <= 2000;
  const modelRates = fresh ? incoming.modelRates.filter(r => Number.isFinite(r.tokensPerSecond) && r.tokensPerSecond > 0) : [];
  const clientRates = fresh ? incoming.clientRates.filter(r => Number.isFinite(r.tokensPerSecond) && r.tokensPerSecond > 0) : [];
  return { ...base, tokensPerSecond: modelRates.reduce((sum, r) => sum + r.tokensPerSecond, 0), modelRates,
    colorRates: preferences.grouping === "client" ? clientRates : modelRates,
    speedDisplayMode: "agentSpeed", speedDisplayStatus: fresh ? DISPLAY_STATUS[incoming.status] ?? incoming.status : enabled ? "等待本地客户端日志" : "实时速率已关闭",
    liveRateAvailable: fresh };
}

export const SPEED_COLORS_KEY = "speedDisplay.customColors.v1";
export const SPEED_PREFERENCES_EVENT = "speed-display-preferences-changed";
export const CLIENT_TITLES: Record<string, string> = {
  "client:codex": "Codex", "client:claudeCode": "Claude CLI", "client:claudeDesktop": "Claude Desktop", "client:deepseek": "DSH",
};
export const CLIENT_COLORS: Record<string, string> = {
  "client:codex": "#72d6a2", "client:claudeCode": "#e99663", "client:claudeDesktop": "#e99663", "client:deepseek": "#568dff",
};
export function validSpeedColor(value: unknown): value is string { return typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value); }
let cachedColors: Record<string, string> = {};
let cacheReady = false;
export function readSpeedColors() {
  if (!cacheReady) {
    cacheReady = true;
    try {
      const raw: unknown = JSON.parse(window.localStorage.getItem(SPEED_COLORS_KEY) ?? "{}");
      if (raw && typeof raw === "object" && !Array.isArray(raw)) {
        cachedColors = Object.fromEntries(Object.entries(raw).filter(([, value]) => validSpeedColor(value)));
      }
    } catch { /* Defaults remain available when storage is blocked. */ }
  }
  return cachedColors;
}
export function invalidateSpeedColors() { cacheReady = false; }
export function writeSpeedColor(key: string, color: string | null) {
  const colors = { ...readSpeedColors() };
  if (validSpeedColor(color)) colors[key] = color.toLowerCase(); else delete colors[key];
  try {
    window.localStorage.setItem(SPEED_COLORS_KEY, JSON.stringify(colors)); cachedColors = colors;
    window.dispatchEvent(new Event(SPEED_PREFERENCES_EVENT));
  } catch { /* Preserve the last stored settings. */ }
}
