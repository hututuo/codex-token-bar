export const SIDEBAR_MODULES = ["overview", "speeds", "tasks", "radar", "credits"] as const;
export type SidebarModule = typeof SIDEBAR_MODULES[number];
export type SidebarModuleVisibility = Record<SidebarModule, boolean>;
export const DEFAULT_MODULE_VISIBILITY: SidebarModuleVisibility = { overview: true, speeds: true, tasks: true, radar: true, credits: true };
export function sidebarModuleForPage(tab: string, section?: string): SidebarModule {
  return tab === "quota" ? section === "speeds" ? "speeds" : "overview" : tab === "running" ? "tasks" : tab === "credits" ? "credits" : "radar";
}
export function sanitizeModuleVisibility(value: unknown): SidebarModuleVisibility {
  const input = value && typeof value === "object" ? value as Record<string, unknown> : {};
  return Object.fromEntries(SIDEBAR_MODULES.map(key => [key, typeof input[key] === "boolean" ? input[key] : true])) as SidebarModuleVisibility;
}
