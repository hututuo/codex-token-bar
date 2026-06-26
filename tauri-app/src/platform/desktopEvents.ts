import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { FLOATING_SETTINGS_EVENT } from "../floating/floatingSettings";
import type { DisplaySurfaceSettings, LiveRateSnapshot } from "../types/dashboard";
import { emitPlatformEvent, listenToEvent, type Unlisten } from "./desktopBridge";

const FLOATING_WINDOW_HIDDEN_EVENT = "floating-window-hidden";
const LIVE_RATE_SNAPSHOT_EVENT = "live-rate-snapshot";
const DISPLAY_SURFACES_EVENT = "display-surfaces-changed";

export function notifyFloatingWindowHidden(): Promise<boolean> {
  return emitPlatformEvent(FLOATING_WINDOW_HIDDEN_EVENT, "emit-floating-window-hidden");
}

export function onFloatingWindowHidden(handler: () => void): Promise<Unlisten> {
  return listenToEvent(FLOATING_WINDOW_HIDDEN_EVENT, handler);
}

export function onLiveRateSnapshot(handler: (snapshot: LiveRateSnapshot) => void): Promise<Unlisten> {
  return listenToEvent<LiveRateSnapshot>(LIVE_RATE_SNAPSHOT_EVENT, handler);
}

export function publishFloatingSettings(settings: FloatingWindowSettings): Promise<boolean> {
  return emitPlatformEvent(FLOATING_SETTINGS_EVENT, "publish-floating-settings", settings);
}

export function onFloatingSettingsChanged(handler: (settings: FloatingWindowSettings) => void): Promise<Unlisten> {
  return listenToEvent<FloatingWindowSettings>(FLOATING_SETTINGS_EVENT, handler);
}

export function publishDisplaySurfaces(settings: DisplaySurfaceSettings): Promise<boolean> {
  return emitPlatformEvent(DISPLAY_SURFACES_EVENT, "publish-display-surfaces", settings);
}

export function onDisplaySurfacesChanged(handler: (settings: DisplaySurfaceSettings) => void): Promise<Unlisten> {
  return listenToEvent<DisplaySurfaceSettings>(DISPLAY_SURFACES_EVENT, handler);
}
