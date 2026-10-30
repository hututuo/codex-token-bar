import type { RunningThreadSummaryStatus } from "../types/threadActivity";
import type { QuotaItem } from "../multiClient/integratedClientModel";
import { arrangedSidebarItems, isSidebarItemVisible, type SidebarLayoutConfig, type SidebarVisibilityLevel } from "./sidebarLayoutModel";

export function quotaWindowsForClient(quotas: readonly QuotaItem[], client: string): QuotaItem[] {
  const rank = (q: QuotaItem) => q.window === "5h" ? 0 : q.window === "7d" ? 1 : 2;
  return quotas.filter(q => q.client === client).sort((a, b) => rank(a) - rank(b));
}
export function sidebarLayoutItems(layout: SidebarLayoutConfig, quotas: readonly QuotaItem[], hasCodex = true): string[] {
  const clients = new Set(quotas.map(q => q.client));
  return arrangedSidebarItems(layout, [...clients]).filter(id =>
    (id.startsWith("quota:") ? clients.has(id.slice(6)) : true) &&
    (hasCodex || (id !== "speed" && id !== "tasks")));
}
export function visibleSidebarItems(
  layout: SidebarLayoutConfig,
  quotas: readonly QuotaItem[],
  hasCodex = true,
  level: SidebarVisibilityLevel = "expanded",
): string[] {
  return sidebarLayoutItems(layout, quotas, hasCodex).filter(id => isSidebarItemVisible(layout, id, level));
}
export function compactSidebarIDs(items: readonly string[], quotas: readonly QuotaItem[]): string[] {
  return items.filter(sidebarHasCompactRepresentation).flatMap(id => id.startsWith("quota:")
    ? quotaWindowsForClient(quotas, id.slice(6)).map(q => q.id)
    : [id]);
}
/** Missing/stale readers cannot invalidate another client's current tasks. */
export function sidebarCombinedTaskStatus(codexStatus: RunningThreadSummaryStatus, includesCodex: boolean, requiresClaude: boolean, claudeReady: boolean): RunningThreadSummaryStatus {
  if ((includesCodex && codexStatus === "ready") || (requiresClaude && claudeReady)) return "ready";
  return includesCodex ? codexStatus : "unavailable";
}

export function sidebarCombinedTaskCounts(codexStatus: RunningThreadSummaryStatus, includesCodex: boolean,
  requiresClaude: boolean, claudeReady: boolean, codexMain: number, codexSubagents: number,
  claudeMain: number, claudeSubagents: number) {
  const status = sidebarCombinedTaskStatus(codexStatus, includesCodex, requiresClaude, claudeReady);
  const useCodex = includesCodex && (codexStatus === "ready" || (status === "stale" && codexStatus === "stale"));
  const useClaude = requiresClaude && claudeReady;
  return { status, main: (useCodex ? codexMain : 0) + (useClaude ? claudeMain : 0),
    subagents: (useCodex ? codexSubagents : 0) + (useClaude ? claudeSubagents : 0) };
}

export function sidebarTaskStateLabel(total: number | null | undefined, status: string): string {
  const count = typeof total === "number" && Number.isFinite(total)
    ? `${Math.max(0, Math.floor(total))} 个`
    : "数量未知";
  if (status === "ready") return `运行任务：${count}，数据最新`;
  if (status === "stale") return `运行任务：最近数据显示 ${count}，数据已过期`;
  if (status === "scanning") return `运行任务：正在更新，${count}`;
  return `运行任务：${count}，状态未知`;
}
export function sidebarHasCompactRepresentation(id: string): boolean { return id.startsWith("quota:") || ["speed", "models", "tasks"].includes(id); }
export function sidebarUsesCompactDot(_id: string): boolean { return false; }
export function fixedSidebarRailLayout(trackCount: number, availableHeight = 900, dotCount = 0) {
  const count = Math.max(0, Math.floor(trackCount));
  const dots = Math.min(count, Math.max(0, Math.floor(dotCount)));
  return { barHeight: 46, gap: 12, height: Math.min(Math.max(30, availableHeight), (count - dots) * 46 + dots * 6 + Math.max(0, count - 1) * 12 + 30) };
}
export function sidebarItemTitle(id: string, clientTitle: (client: string) => string): string {
  if (id.startsWith("quota:")) return clientTitle(id.slice(6)) + " 额度";
  return ({ modeltrace: "模型检测", speed: "实时速度", tps: "正文 TPS", models: "模型占比", tasks: "运行任务", radar: "雷达", credits: "重置卡", clientUsage: "客户端用量" } as Record<string, string>)[id] ?? id;
}
