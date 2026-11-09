import type { Snapshot } from "./MultiClientUsage";

export const RECENT_CHART_CLIENT_KEY = "recentChartClientScope.v1";
export function recentChartAvailableClients(snapshot?: Snapshot): string[] {
  return snapshot?.preferences.filter(p => p.enabled || snapshot.summaries.some(row => row.client === p.client)
    || snapshot.quotas?.some(q => q.client === p.client && q.state === "available" && q.windows.length > 0))
    .map(p => p.client) ?? [];
}
export function resolvedRecentChartClients(selection: string, page: readonly string[], available: readonly string[]): string[] {
  if (selection === "dashboard" || !["all", "codex", ...available].includes(selection)) return [...page];
  return selection === "all" ? ["codex", ...available.filter(id => id !== "codex")] : [selection];
}
