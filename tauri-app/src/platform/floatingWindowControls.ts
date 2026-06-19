import { LogicalSize, PhysicalPosition } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  clearPlatformFailure,
  isDesktopRuntimeAvailable,
  warnPlatformFailure,
  type Unlisten,
} from "./desktopBridge";

export interface DesktopPosition {
  x: number;
  y: number;
}

export async function resizeFloatingWindow(width: number, height: number): Promise<boolean> {
  if (!isDesktopRuntimeAvailable()) {
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

export async function startFloatingWindowDrag(): Promise<boolean> {
  if (!isDesktopRuntimeAvailable()) {
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

export async function setFloatingWindowPosition(position: DesktopPosition): Promise<boolean> {
  if (!isDesktopRuntimeAvailable()) {
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

export async function onFloatingWindowMoved(handler: (position: DesktopPosition) => void): Promise<Unlisten> {
  if (!isDesktopRuntimeAvailable()) {
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
