export const SIDEBAR_MODULES = ["overview", "speeds", "tasks", "radar", "credits", "modeltrace"] as const;
export type SidebarModule = typeof SIDEBAR_MODULES[number];
export type SidebarModuleVisibility = Record<SidebarModule, boolean>;
export const DEFAULT_MODULE_VISIBILITY: SidebarModuleVisibility = { overview: true, speeds: true, tasks: true, radar: true, credits: true, modeltrace: true };
export function sidebarModuleForPage(tab: string, section?: string): SidebarModule {
  return tab === "quota" ? section === "speeds" ? "speeds" : "overview" : tab === "running" ? "tasks" : tab === "credits" ? "credits" : tab === "modeltrace" ? "modeltrace" : "radar";
}
export function sanitizeModuleVisibility(value: unknown): SidebarModuleVisibility {
  const input = value && typeof value === "object" ? value as Record<string, unknown> : {};
  const next = Object.fromEntries(SIDEBAR_MODULES.map(key => [key, typeof input[key] === "boolean" ? input[key] : true])) as SidebarModuleVisibility;
  if (!SIDEBAR_MODULES.some(key => next[key])) next.modeltrace = true;
  return next;
}

export function canHideSidebarModule(visibility: SidebarModuleVisibility, module: SidebarModule): boolean {
  return !visibility[module] || SIDEBAR_MODULES.filter(key => visibility[key]).length > 1;
}
