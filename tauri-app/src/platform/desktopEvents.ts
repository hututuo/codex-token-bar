import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { FLOATING_SETTINGS_EVENT } from "../floating/floatingSettings";
import type {
  AppSettingsSnapshot,
  CodexHomeSourceEnvelope,
  DisplaySurfaceSettings,
  LiveRateSnapshot,
  UnreadSummaryChangedPayload,
} from "../types/dashboard";
import {
  emitPlatformEvent,
  emitPlatformEventTo,
  listenToEvent,
  listenToEventResult,
  type EventSubscriptionResult,
  type Unlisten,
} from "./desktopBridge";

const FLOATING_WINDOW_HIDDEN_EVENT = "floating-window-hidden";
const FLOATING_WINDOW_VISIBILITY_EVENT = "floating-window-visibility-changed";
const LIVE_RATE_SNAPSHOT_EVENT = "live-rate-snapshot";
const UNREAD_SUMMARY_CHANGED_EVENT = "unread-summary-changed";
const DISPLAY_SURFACES_EVENT = "display-surfaces-changed";
const APP_SETTINGS_EVENT = "app-settings-changed";
const OPEN_APP_SETTINGS_EVENT = "open-app-settings";
const FLOATING_WINDOW_LABEL = "floating";
const STATUS_WINDOW_LABEL = "status";
export const CODEX_HOME_SOURCE_CHANGED_EVENT = "codex-home-source-changed";

export function notifyFloatingWindowHidden(): Promise<boolean> {
  return emitPlatformEvent(FLOATING_WINDOW_HIDDEN_EVENT, "emit-floating-window-hidden");
}

export function onFloatingWindowHidden(handler: () => void): Promise<Unlisten> {
  return listenToEvent(FLOATING_WINDOW_HIDDEN_EVENT, handler);
}

export function onFloatingWindowVisibilityChanged(
  handler: (visible: boolean) => void,
): Promise<EventSubscriptionResult> {
  return listenToEventResult<boolean>(FLOATING_WINDOW_VISIBILITY_EVENT, handler);
}

export function onLiveRateSnapshot(handler: (snapshot: LiveRateSnapshot) => void): Promise<Unlisten> {
  return listenToEvent<LiveRateSnapshot>(LIVE_RATE_SNAPSHOT_EVENT, handler);
}

export function publishUnreadSummaryChanged(payload: UnreadSummaryChangedPayload): Promise<boolean> {
  return emitPlatformEvent(UNREAD_SUMMARY_CHANGED_EVENT, "publish-unread-summary", payload);
}

export function onUnreadSummaryChanged(
  handler: (payload: UnreadSummaryChangedPayload) => void,
): Promise<Unlisten> {
  return listenToEvent<UnreadSummaryChangedPayload>(UNREAD_SUMMARY_CHANGED_EVENT, handler);
}

export async function publishFloatingSettings(settings: FloatingWindowSettings): Promise<boolean> {
  const results = await Promise.all([
    emitPlatformEventTo(
      FLOATING_WINDOW_LABEL,
      FLOATING_SETTINGS_EVENT,
      "publish-floating-settings:floating",
      settings,
    ),
    emitPlatformEventTo(
      STATUS_WINDOW_LABEL,
      FLOATING_SETTINGS_EVENT,
      "publish-floating-settings:status",
      settings,
    ),
  ]);
  return results.every(Boolean);
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

export function publishAppSettings(settings: AppSettingsSnapshot): Promise<boolean> {
  return emitPlatformEvent(APP_SETTINGS_EVENT, "publish-app-settings", settings);
}

export function onAppSettingsChanged(handler: (settings: AppSettingsSnapshot) => void): Promise<Unlisten> {
  return listenToEvent<AppSettingsSnapshot>(APP_SETTINGS_EVENT, handler);
}

export function publishOpenAppSettings(): Promise<boolean> {
  return emitPlatformEvent(OPEN_APP_SETTINGS_EVENT, "open-app-settings");
}

export function onOpenAppSettings(handler: () => void): Promise<Unlisten> {
  return listenToEvent(OPEN_APP_SETTINGS_EVENT, handler);
}

export function onCodexHomeSourceChanged(
  handler: (envelope: CodexHomeSourceEnvelope) => void,
): Promise<EventSubscriptionResult> {
  return listenToEventResult<CodexHomeSourceEnvelope>(CODEX_HOME_SOURCE_CHANGED_EVENT, handler);
}
