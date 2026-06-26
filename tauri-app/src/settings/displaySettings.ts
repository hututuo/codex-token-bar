import type { DisplaySurfaceSettings } from "../types/dashboard";
import type { PlatformCapabilities } from "../types/dashboard";

export const DEFAULT_DISPLAY_SURFACES: DisplaySurfaceSettings = {
  floatingWindowEnabled: true,
  liveRateEnabled: true,
  statusTrayLiveTextEnabled: true,
};

export const INACTIVE_DISPLAY_SURFACES: DisplaySurfaceSettings = {
  floatingWindowEnabled: false,
  liveRateEnabled: true,
  statusTrayLiveTextEnabled: false,
};

export function sanitizeDisplaySurfaces(
  settings: Partial<DisplaySurfaceSettings>,
): DisplaySurfaceSettings {
  return {
    floatingWindowEnabled:
      typeof settings.floatingWindowEnabled === "boolean"
        ? settings.floatingWindowEnabled
        : DEFAULT_DISPLAY_SURFACES.floatingWindowEnabled,
    liveRateEnabled:
      typeof settings.liveRateEnabled === "boolean"
        ? settings.liveRateEnabled
        : DEFAULT_DISPLAY_SURFACES.liveRateEnabled,
    statusTrayLiveTextEnabled:
      typeof settings.statusTrayLiveTextEnabled === "boolean"
        ? settings.statusTrayLiveTextEnabled
        : DEFAULT_DISPLAY_SURFACES.statusTrayLiveTextEnabled,
  };
}

export function isPlatformCapabilitiesReady(platform: PlatformCapabilities | null): boolean {
  return platform !== null && platform.platform !== "loading";
}

export function canUseFloatingWindow(platform: PlatformCapabilities | null): boolean {
  return platform !== null && platform.platform !== "loading" && platform.floatingWindow.available;
}

export function canUseStatusTrayLiveText(platform: PlatformCapabilities | null): boolean {
  return (
    platform !== null &&
    platform.platform !== "loading" &&
    platform.statusTray.available &&
    platform.statusTrayLiveText.available
  );
}
