import { useEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { invoke } from "@tauri-apps/api/core";
import { PhysicalPosition, PhysicalSize } from "@tauri-apps/api/dpi";
import { currentMonitor, getCurrentWindow } from "@tauri-apps/api/window";
import { isDesktopRuntimeAvailable, warnPlatformFailure } from "../platform/desktopBridge";
import {
  isFloatingGeometryTransient,
  publishFloatingSettledPosition,
  registerFloatingGeometryLifecycle,
  runFloatingGeometryChange,
} from "../platform/floatingGeometryLifecycle";
import { isFloatingWindowResizeProgrammatic, startFloatingWindowDrag } from "../platform/floatingWindowControls";
import { createFloatingEdgeDockController, FREE_DOCK_PRESENTATION, type DockPresentation } from "./floatingEdgeDock";

export function useFloatingEdgeDock(enabled: boolean, suspended: boolean) {
  const [presentation, setPresentation] = useState<DockPresentation>(FREE_DOCK_PRESENTATION);
  const controller = useRef<ReturnType<typeof createFloatingEdgeDockController> | null>(null);
  const suspendedRef = useRef(suspended);
  suspendedRef.current = suspended;

  useEffect(() => {
    if (!enabled || !isDesktopRuntimeAvailable()) return;
    let disposed = false;
    const appWindow = getCurrentWindow();
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    const dock = createFloatingEdgeDockController({
      async geometry() {
        const [position, size, monitor, scaleFactor] = await Promise.all([
          appWindow.outerPosition(), appWindow.outerSize(), currentMonitor(), appWindow.scaleFactor(),
        ]);
        if (!monitor) throw new Error("No monitor work area for floating window");
        return {
          frame: { x: position.x, y: position.y, width: size.width, height: size.height },
          workArea: { x: monitor.workArea.position.x, y: monitor.workArea.position.y,
            width: monitor.workArea.size.width, height: monitor.workArea.size.height },
          scaleFactor,
        };
      },
      pointer: () => invoke("read_floating_pointer_state"),
      frame: (rect) => runFloatingGeometryChange(async () => {
        // Boundary writes remain transient and never enter normal placement
        // persistence; animation frames never cross this native API boundary.
        const size = new PhysicalSize(Math.max(1, Math.round(rect.width)), Math.max(1, Math.round(rect.height)));
        const position = new PhysicalPosition(Math.round(rect.x), Math.round(rect.y));
        await appWindow.setSize(size);
        await appWindow.setPosition(position);
        const actual = await appWindow.outerSize();
        if (Math.abs(actual.width - size.width) > 2 || Math.abs(actual.height - size.height) > 2) {
          throw new Error("Native floating window constraints rejected the requested dock size");
        }
      }),
      persist: publishFloatingSettledPosition,
      present(value) { if (!disposed) flushSync(() => setPresentation(value)); },
      reducedMotion: () => reduced.matches,
      startDrag: startFloatingWindowDrag,
      report: (error) => warnPlatformFailure("floating-edge-dock", error),
    });
    controller.current = dock;
    const unregister = registerFloatingGeometryLifecycle(dock);
    const listeners: (() => void)[] = [];
    const register = (promise: Promise<() => void>) => {
      void promise.then((remove) => { if (disposed) remove(); else listeners.push(remove); }).catch((error) => warnPlatformFailure("floating-edge-dock-listener", error));
    };
    register(appWindow.onMoved(() => {
      if (!isFloatingGeometryTransient() && !isFloatingWindowResizeProgrammatic()) dock.moved();
    }));
    register(appWindow.onScaleChanged(() => { if (!isFloatingGeometryTransient()) dock.moved(); }));
    const release = () => dock.interactionEnded();
    window.addEventListener("pointerup", release);
    void dock.suspend(suspendedRef.current).catch((error) => warnPlatformFailure("floating-edge-dock", error));
    if (!suspendedRef.current) dock.initialize();
    return () => {
      disposed = true;
      dock.dispose();
      unregister();
      for (const remove of listeners) remove();
      window.removeEventListener("pointerup", release);
      if (controller.current === dock) controller.current = null;
    };
  }, [enabled]);

  useEffect(() => {
    void controller.current?.suspend(suspended).catch((error) => warnPlatformFailure("floating-edge-dock", error));
  }, [suspended]);

  return {
    presentation,
    hover: (inside: boolean) => controller.current?.hover(inside),
    reveal: () => { void controller.current?.reveal().catch((error) => warnPlatformFailure("floating-edge-dock", error)); },
    startDrag: () => {
      if (controller.current) void controller.current.startDrag().catch((error) => warnPlatformFailure("floating-edge-dock", error));
      else void startFloatingWindowDrag();
    },
  };
}
