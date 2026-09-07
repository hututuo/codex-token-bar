import { floatingGeometryLifecycle, isFloatingGeometryTransient, runFloatingGeometryChange } from "./floatingGeometryLifecycle";
import { PhysicalPosition } from "@tauri-apps/api/dpi";
import { invoke } from "@tauri-apps/api/core";
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


export interface FloatingWindowResizeOptions {
  targetPosition?: DesktopPosition;
}

let programmaticPosition: DesktopPosition | null = null;
let programmaticResizeUntil = 0;

export async function resizeFloatingWindow(
  width: number,
  height: number,
  options: FloatingWindowResizeOptions = {},
): Promise<boolean> {
  if (!isDesktopRuntimeAvailable()) {
    return false;
  }

  const dockLifecycle = floatingGeometryLifecycle();
  try {
    await dockLifecycle?.beforeResize();
    const appWindow = getCurrentWindow();
    programmaticResizeUntil = Date.now() + 1_000;
    const targetPosition = options.targetPosition;

    await runFloatingGeometryChange(async () => {
      const [scaleFactor, current] = await Promise.all([appWindow.scaleFactor(), appWindow.outerPosition()]);
      const position = targetPosition ?? current;
      markFloatingWindowPositionProgrammatic(position);
      // Commit origin and size together, especially when a bottom-edge drawer
      // grows upward. Restore the normal full WebKit viewport at this boundary.
      await invoke("set_floating_dock_frame", { frame: {
        x: Math.round(position.x), y: Math.round(position.y),
        width: Math.round(width * scaleFactor), height: Math.round(height * scaleFactor),
      }, viewport: null });
    });
    programmaticResizeUntil = Date.now() + 250;
    clearPlatformFailure("resize-floating-window");
    return true;
  } catch (error) {
    programmaticResizeUntil = 0;
    programmaticPosition = null;
    warnPlatformFailure("resize-floating-window", error);
    return false;
  } finally {
    dockLifecycle?.afterResize();
  }
}

export function markFloatingWindowPositionProgrammatic(position: DesktopPosition): void {
  programmaticPosition = position;
}

export function consumeFloatingWindowPositionIfProgrammatic(position: DesktopPosition): boolean {
  if (Date.now() >= programmaticResizeUntil) {
    programmaticPosition = null;
  }
  if (!programmaticPosition || !samePosition(programmaticPosition, position)) {
    return false;
  }
  programmaticPosition = null;
  return true;
}

export function isFloatingWindowResizeProgrammatic(): boolean {
  return isFloatingGeometryTransient() || Date.now() < programmaticResizeUntil;
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

function samePosition(left: DesktopPosition, right: DesktopPosition): boolean {
  return left.x === right.x && left.y === right.y;
}
