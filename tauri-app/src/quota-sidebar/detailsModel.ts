import type { ModelTokenBreakdown } from "../types/dashboard";

export interface SidebarModelUsage { model: string | null; tokens: number; percent: number }
/** Total tokens already include cached input. Never add cache components again. */
export function sidebarTodayModels(rows: readonly ModelTokenBreakdown[] = [], limit = 4): SidebarModelUsage[] {
  const totals = new Map<string | null, number>();
  let allTokens = 0;
  for (const row of rows) {
    const tokens = row.breakdown.totalTokens;
    // An invalid bucket makes the denominator unknowable; do not fabricate shares.
    if (!Number.isFinite(tokens) || tokens < 0) return [];
    allTokens += tokens;
    totals.set(row.model, (totals.get(row.model) ?? 0) + tokens);
  }
  if (!(allTokens > 0) || !Number.isFinite(allTokens)) return [];
  return [...totals].map(([model, tokens]) => ({ model, tokens, percent: tokens / allTokens * 100 }))
    .filter(row => row.tokens > 0).sort((a, b) => b.tokens - a.tokens).slice(0, limit);
}
export function sidebarLocalTime(value: string | undefined, unix?: number | null, updated = false): string {
  const date = typeof unix === "number" && Number.isFinite(unix) ? new Date(unix * 1000) : new Date(value ?? "");
  if (Number.isNaN(date.getTime())) return value || (updated ? "尚未更新" : "重置时间未知");
  const sameDay = date.toDateString() === new Date().toDateString();
  return date.toLocaleString("zh-CN", { ...(updated && sameDay ? {} : { month: "numeric", day: "numeric" }), hour: "2-digit", minute: "2-digit", hour12: false });
}
export function sidebarMetricValue(value: string | undefined): string {
  return value?.replace(/^(?:总|今|次)\s+/, "") || "未知";
}

/** Split local reset time into two short lines that fit inside a 49px ring. */
export function sidebarRingResetTime(value?: string, unix?: number | null) {
  const date = typeof unix === "number" && Number.isFinite(unix)
    ? new Date(unix * 1000) : new Date(value ?? "");
  if (Number.isNaN(date.getTime())) return null;
  const pad = (number: number) => String(number).padStart(2, "0");
  return {
    date: `${date.getMonth() + 1}/${date.getDate()}`,
    time: `${pad(date.getHours())}:${pad(date.getMinutes())}`,
    dateTime: date.toISOString(),
    title: `重置时间：${sidebarLocalTime(value, unix)}（本地时间）`,
  };
}
