import { useEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { invoke } from "@tauri-apps/api/core";
import { currentMonitor, getCurrentWindow } from "@tauri-apps/api/window";
import { recordPerformanceEvent } from "../api/startupClient";
import { isDesktopRuntimeAvailable, warnPlatformFailure } from "../platform/desktopBridge";
import {
  isFloatingGeometryTransient,
  publishFloatingSettledPosition,
  registerFloatingGeometryLifecycle,
  runFloatingGeometryChange,
} from "../platform/floatingGeometryLifecycle";
import { isFloatingWindowResizeProgrammatic, startFloatingWindowDrag } from "../platform/floatingWindowControls";
import { waitForDockViewport, waitForDockPaint } from "./floatingDockPaintHandoff";
import { createFloatingEdgeDockController, FREE_DOCK_PRESENTATION, type DockPresentation } from "./floatingEdgeDock";

export function useFloatingEdgeDock(enabled: boolean, suspended: boolean, heldOpen = false) {
  const [presentation, setPresentation] = useState<DockPresentation>(FREE_DOCK_PRESENTATION);
  const controller = useRef<ReturnType<typeof createFloatingEdgeDockController> | null>(null);
  const suspendedRef = useRef(suspended);
  suspendedRef.current = suspended;

  useEffect(() => {
    if (!enabled || !isDesktopRuntimeAvailable()) return;
    let disposed = false;
    const appWindow = getCurrentWindow();
    const nativeProbe = new URLSearchParams(window.location.search).get("dockProbe") === "1";
    let frameCommit = { viewportPinned: false, waitForPaint: true };
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
        const size = { width: Math.max(1, Math.round(rect.width)), height: Math.max(1, Math.round(rect.height)) };
        const anchor = dock.state().anchor;
        const matches = (target: typeof rect) => ["x", "y", "width", "height"].every(key =>
          Math.abs(rect[key as keyof typeof rect] - target[key as keyof typeof rect]) < 1);
        const viewport = anchor && (matches(anchor.frame) || matches(anchor.lip)) ? anchor.frame : null;
        frameCommit = await invoke<{ viewportPinned: boolean; waitForPaint: boolean }>("set_floating_dock_frame", {
          frame: { x: Math.round(rect.x), y: Math.round(rect.y), ...size }, viewport,
        });
        const actual = await appWindow.outerSize();
        if (Math.abs(actual.width - size.width) > 2 || Math.abs(actual.height - size.height) > 2) {
          throw new Error("Native floating window constraints rejected the requested dock size");
        }
      }),
      persist: publishFloatingSettledPosition,
      present(value) { if (!disposed) flushSync(() => setPresentation(value)); },
      reducedMotion: () => reduced.matches,
      probe(phase, state) {
        if (!nativeProbe) return;
        const snapshot = (paintPhase: string) => {
          const host = document.querySelector<HTMLElement>(".floating-edge-host")?.getBoundingClientRect();
          const shell = document.querySelector<HTMLElement>(".floating-edge-shell");
          const shellRect = shell?.getBoundingClientRect();
          const base = document.querySelector<HTMLElement>(".floating-edge-base")?.getBoundingClientRect();
          const transform = shell ? getComputedStyle(shell).transform : "none";
          void recordPerformanceEvent(
            `floating_probe phase=${phase}/${paintPhase} inner=${window.innerWidth}x${window.innerHeight}`
            + ` state=${state.collapsed ? 1 : 0},${state.compact ? 1 : 0},${state.railReady ? 1 : 0},${state.motion}`
            + ` commit=${frameCommit.viewportPinned ? 1 : 0},${frameCommit.waitForPaint ? 1 : 0}`
            + ` host=${host ? `${host.x.toFixed(1)},${host.y.toFixed(1)},${host.width.toFixed(1)},${host.height.toFixed(1)}` : "missing"}`
            + ` shell=${shellRect ? `${shellRect.x.toFixed(1)},${shellRect.y.toFixed(1)},${shellRect.width.toFixed(1)},${shellRect.height.toFixed(1)}` : "missing"}`
            + ` base=${base ? `${base.x.toFixed(1)},${base.y.toFixed(1)},${base.width.toFixed(1)},${base.height.toFixed(1)}` : "missing"}`
            + ` transform=${transform}`,
          );
        };
        snapshot("return");
        requestAnimationFrame(() => {
          snapshot("raf1");
          requestAnimationFrame(() => snapshot("raf2"));
        });
      },
      async prepareCompact(anchor) {
        const viewport = frameCommit.viewportPinned ? anchor.frame : anchor.lip;
        await waitForDockViewport(viewport.width / anchor.scaleFactor, viewport.height / anchor.scaleFactor);
        if (frameCommit.waitForPaint) await waitForDockPaint();
      },
      async prepareReveal() {
        const anchor = dock.state().anchor;
        if (anchor) await waitForDockViewport(anchor.frame.width / anchor.scaleFactor, anchor.frame.height / anchor.scaleFactor);
        // Resolve the collapsed style in the expanded native viewport before
        // starting its transition, without introducing a hover-delay timer.
        const shell = document.querySelector(".floating-edge-shell");
        if (shell) void getComputedStyle(shell).transform;
        // A pinned viewport only proves layout size. WebView2 can still publish
        // the newly moved backing surface later than the Win32 geometry call,
        // so the native command explicitly tells us whether to hold the rail
        // mask through an additional paint boundary.
        if (frameCommit.waitForPaint) await waitForDockPaint();
      },
      startDrag: startFloatingWindowDrag,
      report: (error) => warnPlatformFailure("floating-edge-dock", error),
    });
    controller.current = dock;
    const unregister = registerFloatingGeometryLifecycle(dock);
    const listeners: (() => void)[] = [];
    const register = (promise: Promise<() => void>) => {
      void promise.then((remove) => { if (disposed) remove(); else listeners.push(remove); }).catch((error) => warnPlatformFailure("floating-edge-dock-listener", error));
    };
    register(appWindow.listen<boolean>("floating-native-hover", (event) => dock.hover(event.payload)));
    register(appWindow.onMoved(() => {
      if (!isFloatingGeometryTransient() && !isFloatingWindowResizeProgrammatic()) dock.moved();
    }));
    register(appWindow.onScaleChanged(() => { if (!isFloatingGeometryTransient()) dock.moved(); }));
    const release = () => dock.interactionEnded();
    window.addEventListener("pointerup", release);
    void dock.suspend(suspendedRef.current).catch((error) => warnPlatformFailure("floating-edge-dock", error));
    if (!suspendedRef.current && !nativeProbe) dock.initialize();
    if (!suspendedRef.current && nativeProbe) {
      window.setTimeout(() => {
        void recordPerformanceEvent("floating_probe begin");
        void dock.runRightEdgeProbe().then(
          () => recordPerformanceEvent("floating_probe complete"),
          error => recordPerformanceEvent(`floating_probe failed ${error instanceof Error ? error.message : String(error)}`),
        );
      }, 450);
    }
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

  useEffect(() => {
    void controller.current?.holdOpen(heldOpen).catch((error) => warnPlatformFailure("floating-edge-dock", error));
  }, [heldOpen, enabled]);

  return {
    presentation,
    controller,
    expandedFrame: () => controller.current?.state().anchor?.frame,
    hover: (inside: boolean) => controller.current?.hover(inside),
    reveal: () => { void controller.current?.reveal().catch((error) => warnPlatformFailure("floating-edge-dock", error)); },
    startDrag: () => {
      if (controller.current) void controller.current.startDrag().catch((error) => warnPlatformFailure("floating-edge-dock", error));
      else void startFloatingWindowDrag();
    },
  };
}
