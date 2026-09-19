/** Applied before React mounts, matching the native canvas implementation. */
export function sidebarCanvasClasses(surface: string, platform: string): string[] {
  if (surface !== "quota-sidebar") return [];
  if (/Win/.test(platform)) return ["quota-sidebar-fixed-canvas", "quota-sidebar-windows-canvas"];
  if (/Mac/.test(platform)) return ["quota-sidebar-fixed-canvas"];
  return [];
}
