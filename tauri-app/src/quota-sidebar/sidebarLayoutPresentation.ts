import type { QuotaItem } from "../multiClient/integratedClientModel";
import { arrangedSidebarItems, isSidebarItemVisible, type SidebarLayoutConfig } from "./sidebarLayoutModel";

export function quotaWindowsForClient(quotas: readonly QuotaItem[], client: string): QuotaItem[] {
  const rank = (q: QuotaItem) => q.window === "5h" ? 0 : q.window === "7d" ? 1 : 2;
  return quotas.filter(q => q.client === client).sort((a, b) => rank(a) - rank(b));
}
export function sidebarLayoutItems(layout: SidebarLayoutConfig, quotas: readonly QuotaItem[], hasCodex = true): string[] {
  const clients = new Set(quotas.map(q => q.client));
  return arrangedSidebarItems(layout, [...clients]).filter(id =>
    (id.startsWith("quota:") ? clients.has(id.slice(6)) : true) &&
    (hasCodex || (id !== "speed" && id !== "models")));
}
export function visibleSidebarItems(layout: SidebarLayoutConfig, quotas: readonly QuotaItem[], hasCodex = true): string[] {
  return sidebarLayoutItems(layout, quotas, hasCodex).filter(id => isSidebarItemVisible(layout, id));
}
export function compactSidebarIDs(items: readonly string[], quotas: readonly QuotaItem[]): string[] {
  return items.flatMap(id => id.startsWith("quota:")
    ? quotaWindowsForClient(quotas, id.slice(6)).map(q => q.id)
    : id === "speed" || id === "models" ? [id] : []);
}
export function fixedSidebarRailLayout(trackCount: number, availableHeight = 900) {
  const count = Math.max(0, Math.floor(trackCount));
  return { barHeight: 46, gap: 12, height: Math.min(Math.max(30, availableHeight), count * 46 + Math.max(0, count - 1) * 12 + 30) };
}
export function sidebarItemTitle(id: string, clientTitle: (client: string) => string): string {
  if (id.startsWith("quota:")) return clientTitle(id.slice(6)) + " 额度";
  return ({ modeltrace: "模型检测", speed: "实时速度", tps: "正文 TPS", models: "模型占比", tasks: "运行任务", radar: "雷达", credits: "重置卡", clientUsage: "客户端用量" } as Record<string, string>)[id] ?? id;
}
