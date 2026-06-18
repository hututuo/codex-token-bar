import { invoke } from "@tauri-apps/api/core";
import { LogicalSize, PhysicalPosition } from "@tauri-apps/api/dpi";
import { emit, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { clearCommandFailure, recordCommandFailure } from "../diagnostics/localDiagnostics";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { FLOATING_SETTINGS_EVENT } from "../floating/floatingSettings";
import type { LiveRateSnapshot } from "../types/dashboard";
import { isTauriRuntimeAvailable, withTimeout } from "./runtime";

export type SurfaceMode = "dashboard" | "floating" | "status";

export interface DesktopPosition {
  x: number;
  y: number;
}

type Unlisten = () => void;

const FLOATING_WINDOW_HIDDEN_EVENT = "floating-window-hidden";
const LIVE_RATE_SNAPSHOT_EVENT = "live-rate-snapshot";
const PLATFORM_COMMAND_TIMEOUT_MS = 2_000;

export const desktopPlatform = {
  isAvailable: isTauriRuntimeAvailable,
  getSurfaceMode,
  showFloatingWindow,
  hideFloatingWindow,
  showStatusPanelWindow,
  hideStatusPanelWindow,
  showDashboardWindow,
  notifyFloatingWindowHidden,
  onFloatingWindowHidden,
  publishFloatingSettings,
  onFloatingSettingsChanged,
  resizeFloatingWindow,
  startFloatingWindowDrag,
  setFloatingWindowPosition,
  onFloatingWindowMoved,
  setStatusTrayReadout,
  startLiveRateStream,
  stopLiveRateStream,
  onLiveRateSnapshot,
};

function getSurfaceMode(): SurfaceMode {
  const surface = new URLSearchParams(window.location.search).get("surface");
  if (surface === "floating" || surface === "status") {
    return surface;
  }
  return "dashboard";
}

function showFloatingWindow(): Promise<boolean> {
  return invokePlatformCommand("show_floating_window", false);
}

function hideFloatingWindow(): Promise<boolean> {
  return invokePlatformCommand("hide_floating_window", true);
}

function showStatusPanelWindow(): Promise<boolean> {
  return invokePlatformCommand("show_status_panel_window", false);
}

function hideStatusPanelWindow(): Promise<boolean> {
  return invokePlatformCommand("hide_status_panel_window", true);
}

function showDashboardWindow(): Promise<boolean> {
  return invokePlatformCommand("show_dashboard_window", false);
}

function setStatusTrayReadout(title: string, tooltip: string): Promise<boolean> {
  return invokePlatformCommand("set_status_tray_readout", false, { title, tooltip });
}

function startLiveRateStream(selectedThreadId?: string | null): Promise<boolean> {
  return invokePlatformCommand("start_live_rate_stream", false, {
    selectedThreadId: selectedThreadId || null,
  });
}

function stopLiveRateStream(): Promise<boolean> {
  return invokePlatformCommand("stop_live_rate_stream", false);
}

async function notifyFloatingWindowHidden(): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await emit(FLOATING_WINDOW_HIDDEN_EVENT);
    clearPlatformFailure("emit-floating-window-hidden");
    return true;
  } catch (error) {
    warnPlatformFailure("emit-floating-window-hidden", error);
    return false;
  }
}

function onFloatingWindowHidden(handler: () => void): Promise<Unlisten> {
  return listenToEvent(FLOATING_WINDOW_HIDDEN_EVENT, handler);
}

function onLiveRateSnapshot(handler: (snapshot: LiveRateSnapshot) => void): Promise<Unlisten> {
  return listenToEvent<LiveRateSnapshot>(LIVE_RATE_SNAPSHOT_EVENT, handler);
}

async function publishFloatingSettings(settings: FloatingWindowSettings): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await emit(FLOATING_SETTINGS_EVENT, settings);
    clearPlatformFailure("publish-floating-settings");
    return true;
  } catch (error) {
    warnPlatformFailure("publish-floating-settings", error);
    return false;
  }
}

function onFloatingSettingsChanged(handler: (settings: FloatingWindowSettings) => void): Promise<Unlisten> {
  return listenToEvent<FloatingWindowSettings>(FLOATING_SETTINGS_EVENT, handler);
}

async function resizeFloatingWindow(width: number, height: number): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await getCurrentWindow().setSize(new LogicalSize(width, height));
    clearPlatformFailure("resize-floating-window");
    return true;
  } catch (error) {
    warnPlatformFailure("resize-floating-window", error);
    return false;
  }
}

async function startFloatingWindowDrag(): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await getCurrentWindow().startDragging();
    clearPlatformFailure("start-floating-window-drag");
    return true;
  } catch (error) {
    warnPlatformFailure("start-floating-window-drag", error);
    return false;
  }
}

async function setFloatingWindowPosition(position: DesktopPosition): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await getCurrentWindow().setPosition(new PhysicalPosition(position.x, position.y));
    clearPlatformFailure("restore-floating-window-position");
    return true;
  } catch (error) {
    warnPlatformFailure("restore-floating-window-position", error);
    return false;
  }
}

async function onFloatingWindowMoved(handler: (position: DesktopPosition) => void): Promise<Unlisten> {
  if (!isTauriRuntimeAvailable()) {
    return () => {};
  }

  try {
    const unlisten = await getCurrentWindow().onMoved(({ payload }) => {
      handler({ x: payload.x, y: payload.y });
    });
    clearPlatformFailure("listen-floating-window-moved");
    return unlisten;
  } catch (error) {
    warnPlatformFailure("listen-floating-window-moved", error);
    return () => {};
  }
}

async function invokePlatformCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    return fallback;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), PLATFORM_COMMAND_TIMEOUT_MS);
    clearPlatformFailure(`command:${command}`);
    return result;
  } catch (error) {
    warnPlatformFailure(`command:${command}`, error);
    return fallback;
  }
}

async function listenToEvent<T = void>(
  eventName: string,
  handler: (payload: T) => void,
): Promise<Unlisten> {
  if (!isTauriRuntimeAvailable()) {
    return () => {};
  }

  try {
    const unlisten = await listen<T>(eventName, ({ payload }) => handler(payload));
    clearPlatformFailure(`listen:${eventName}`);
    return unlisten;
  } catch (error) {
    warnPlatformFailure(`listen:${eventName}`, error);
    return () => {};
  }
}

function warnPlatformFailure(key: string, error: unknown) {
  recordCommandFailure(platformDiagnosticKey(key), error);
}

function clearPlatformFailure(key: string) {
  clearCommandFailure(platformDiagnosticKey(key));
}

function platformDiagnosticKey(key: string) {
  return `platform:${key}`;
}
