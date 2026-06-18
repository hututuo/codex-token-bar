import type { DisplaySurfaceSettings } from "../types/dashboard";

export const DEFAULT_DISPLAY_SURFACES: DisplaySurfaceSettings = {
  floatingWindowEnabled: true,
  statusTrayLiveTextEnabled: true,
};

export function sanitizeDisplaySurfaces(
  settings: Partial<DisplaySurfaceSettings>,
): DisplaySurfaceSettings {
  return {
    floatingWindowEnabled:
      typeof settings.floatingWindowEnabled === "boolean"
        ? settings.floatingWindowEnabled
        : DEFAULT_DISPLAY_SURFACES.floatingWindowEnabled,
    statusTrayLiveTextEnabled:
      typeof settings.statusTrayLiveTextEnabled === "boolean"
        ? settings.statusTrayLiveTextEnabled
        : DEFAULT_DISPLAY_SURFACES.statusTrayLiveTextEnabled,
  };
}
