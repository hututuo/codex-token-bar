export const SIDEBAR_MODULES = ["overview", "speeds", "tasks", "radar", "credits", "modeltrace"] as const;
export type SidebarModule = typeof SIDEBAR_MODULES[number];
export type SidebarModuleVisibility = Record<SidebarModule, boolean>;
export const DEFAULT_MODULE_VISIBILITY: SidebarModuleVisibility = { overview: true, speeds: true, tasks: true, radar: true, credits: true, modeltrace: true };
export function sidebarModuleForPage(tab: string, section?: string): SidebarModule | null {
  if (tab === "settings") return null;
  return tab === "quota" ? section === "speeds" ? "speeds" : "overview" : tab === "running" ? "tasks" : tab === "credits" ? "credits" : tab === "modeltrace" ? "modeltrace" : "radar";
}
export function sanitizeModuleVisibility(value: unknown): SidebarModuleVisibility {
  const input = value && typeof value === "object" ? value as Record<string, unknown> : {};
  const next = Object.fromEntries(SIDEBAR_MODULES.map(key => [key, typeof input[key] === "boolean" ? input[key] : true])) as SidebarModuleVisibility;
  return next;
}

export const DEFAULT_MODULE_ORDER: readonly SidebarModule[] = ["modeltrace", "speeds", "overview", "tasks", "radar", "credits"];
export const SIDEBAR_MODULE_TITLES: Record<SidebarModule, string> = { modeltrace:"模型检测", speeds:"速率与正文 TPS", overview:"额度与模型占比", tasks:"运行任务", radar:"雷达", credits:"重置卡" };
export function sanitizeModuleOrder(value: unknown): SidebarModule[] {
  const result: SidebarModule[] = [];
  if (Array.isArray(value)) for (const entry of value) {
    if (DEFAULT_MODULE_ORDER.includes(entry) && !result.includes(entry)) result.push(entry);
  }
  return [...result, ...DEFAULT_MODULE_ORDER.filter(module => !result.includes(module))];
}
export function moveSidebarModule(order: readonly SidebarModule[], module: SidebarModule, offset: number): SidebarModule[] {
  const next = [...order], index = next.indexOf(module), target = index + offset;
  if (index >= 0 && target >= 0 && target < next.length) [next[index], next[target]] = [next[target], next[index]];
  return next;
}
