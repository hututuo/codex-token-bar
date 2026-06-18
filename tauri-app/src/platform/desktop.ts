import { invoke } from "@tauri-apps/api/core";
import { LogicalSize, PhysicalPosition } from "@tauri-apps/api/dpi";
import { emit, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type { FloatingWindowSettings } from "../floating/floatingSettings";
import { FLOATING_SETTINGS_EVENT } from "../floating/floatingSettings";
import { isTauriRuntimeAvailable, withTimeout } from "./runtime";

export type SurfaceMode = "dashboard" | "floating" | "status";

export interface DesktopPosition {
  x: number;
  y: number;
}

type Unlisten = () => void;

const FLOATING_WINDOW_HIDDEN_EVENT = "floating-window-hidden";
const PLATFORM_COMMAND_TIMEOUT_MS = 2_000;
const WARNING_THROTTLE_MS = 5_000;
const lastPlatformWarningAtByKey = new Map<string, number>();

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
};

function getSurfaceMode(): SurfaceMode {
  const surface = new URLSearchParams(window.location.search).get("surface");
  if (surface === "floating" || surface === "status") {
    return surface;
  }

  if (!isTauriRuntimeAvailable()) {
    return "dashboard";
  }

  try {
    const label = getCurrentWindow().label;
    return label === "floating" || label === "status" ? label : "dashboard";
  } catch (error) {
    warnPlatformFailure("read-window-label", error);
    return "dashboard";
  }
}

function showFloatingWindow(): Promise<boolean> {
  return invokePlatformCommand("show_floating_window", true);
}

function hideFloatingWindow(): Promise<boolean> {
  return invokePlatformCommand("hide_floating_window", false);
}

function showStatusPanelWindow(): Promise<boolean> {
  return invokePlatformCommand("show_status_panel_window", true);
}

function hideStatusPanelWindow(): Promise<boolean> {
  return invokePlatformCommand("hide_status_panel_window", false);
}

function showDashboardWindow(): Promise<boolean> {
  return invokePlatformCommand("show_dashboard_window", true);
}

function setStatusTrayReadout(title: string, tooltip: string): Promise<boolean> {
  return invokePlatformCommand("set_status_tray_readout", false, { title, tooltip });
}

async function notifyFloatingWindowHidden(): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await emit(FLOATING_WINDOW_HIDDEN_EVENT);
    return true;
  } catch (error) {
    warnPlatformFailure("emit-floating-window-hidden", error);
    return false;
  }
}

function onFloatingWindowHidden(handler: () => void): Promise<Unlisten> {
  return listenToEvent(FLOATING_WINDOW_HIDDEN_EVENT, handler);
}

async function publishFloatingSettings(settings: FloatingWindowSettings): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await emit(FLOATING_SETTINGS_EVENT, settings);
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
    return await getCurrentWindow().onMoved(({ payload }) => {
      handler({ x: payload.x, y: payload.y });
    });
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
    return await withTimeout(invoke<T>(command, args), PLATFORM_COMMAND_TIMEOUT_MS);
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
    return await listen<T>(eventName, ({ payload }) => handler(payload));
  } catch (error) {
    warnPlatformFailure(`listen:${eventName}`, error);
    return () => {};
  }
}

function warnPlatformFailure(key: string, error: unknown) {
  const now = Date.now();
  const lastWarningAt = lastPlatformWarningAtByKey.get(key) ?? 0;
  if (now - lastWarningAt < WARNING_THROTTLE_MS) {
    return;
  }

  lastPlatformWarningAtByKey.set(key, now);
  console.warn(`Desktop platform failed: ${key}`, error);
}
