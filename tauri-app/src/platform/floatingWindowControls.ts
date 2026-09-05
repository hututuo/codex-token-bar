import { LogicalSize, PhysicalPosition } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  clearPlatformFailure,
  isDesktopRuntimeAvailable,
  warnPlatformFailure,
  type Unlisten,
} from "./desktopBridge";
import type { FloatingRunningModelDetailsPlacement } from "../floating/floatingWindowPlacement";

export interface DesktopPosition {
  x: number;
  y: number;
}

export type { FloatingRunningModelDetailsPlacement } from "../floating/floatingWindowPlacement";

export interface FloatingWindowResizeOptions {
  basePosition?: DesktopPosition;
  placement?: FloatingRunningModelDetailsPlacement;
  surfaceWidth?: number;
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

  try {
    const appWindow = getCurrentWindow();
    programmaticResizeUntil = Date.now() + 1_000;
    let targetPosition: DesktopPosition | null = null;
    if (options.basePosition) {
      const scaleFactor = await appWindow.scaleFactor();
      const expandedWidth = width * scaleFactor;
      const surfaceWidth = (options.surfaceWidth ?? width) * scaleFactor;
      const extraWidth = Math.max(0, expandedWidth - surfaceWidth);
      targetPosition = {
        x: Math.round(
          options.basePosition.x
            + (options.placement === "leading" ? -extraWidth : 0),
        ),
        y: options.basePosition.y,
      };
    }

    await appWindow.setSize(new LogicalSize(width, height));
    if (targetPosition) {
      markFloatingWindowPositionProgrammatic(targetPosition);
      try {
        await appWindow.setPosition(new PhysicalPosition(targetPosition.x, targetPosition.y));
      } catch (error) {
        programmaticPosition = null;
        throw error;
      }
    }
    programmaticResizeUntil = Date.now() + 250;
    clearPlatformFailure("resize-floating-window");
    return true;
  } catch (error) {
    programmaticResizeUntil = 0;
    programmaticPosition = null;
    warnPlatformFailure("resize-floating-window", error);
    return false;
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
  return Date.now() < programmaticResizeUntil;
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
