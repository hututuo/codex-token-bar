export type FloatingDockEdge = "left" | "right" | "top" | "bottom";
export interface DockRect { x: number; y: number; width: number; height: number }
export interface DockGeometry { frame: DockRect; workArea: DockRect; scaleFactor: number }
export interface DockAnchor { edge: FloatingDockEdge; frame: DockRect; lip: DockRect; scaleFactor: number }
export interface DockPresentation {
  anchor: DockAnchor | null;
  collapsed: boolean;
  compact: boolean;
  railReady: boolean;
  motion: "none" | "expand" | "collapse";
}
export const FREE_DOCK_PRESENTATION: DockPresentation = { anchor: null, collapsed: false, compact: false, railReady: false, motion: "none" };

export function containsDockPoint(rect: DockRect, point: { x: number; y: number }): boolean {
  return point.x >= rect.x && point.x <= rect.x + rect.width && point.y >= rect.y && point.y <= rect.y + rect.height;
}

// Native Tauri coordinates are physical pixels, with a top-left origin. Keep
// all geometry in that space and convert only at the CSS presentation boundary.
export function resolveDockAnchor({ frame, workArea, scaleFactor }: DockGeometry): DockAnchor | null {
  if (![...Object.values(frame), ...Object.values(workArea), scaleFactor].every(Number.isFinite)
    || scaleFactor <= 0 || frame.width <= 6 * scaleFactor || frame.height <= 6 * scaleFactor
    || frame.width > workArea.width || frame.height > workArea.height
    || frame.x + frame.width <= workArea.x || frame.x >= workArea.x + workArea.width
    || frame.y + frame.height <= workArea.y || frame.y >= workArea.y + workArea.height) return null;
  const distances: [FloatingDockEdge, number][] = [
    ["left", frame.x - workArea.x],
    ["right", workArea.x + workArea.width - frame.x - frame.width],
    ["top", frame.y - workArea.y],
    ["bottom", workArea.y + workArea.height - frame.y - frame.height],
  ];
  distances.sort((a, b) => a[1] - b[1]);
  const [edge, distance] = distances[0];
  if (distance > 48 * scaleFactor) return null;
  const snapped = {
    ...frame,
    x: Math.min(Math.max(frame.x, workArea.x), workArea.x + workArea.width - frame.width),
    y: Math.min(Math.max(frame.y, workArea.y), workArea.y + workArea.height - frame.height),
  };
  if (edge === "left") snapped.x = workArea.x;
  if (edge === "right") snapped.x = workArea.x + workArea.width - frame.width;
  if (edge === "top") snapped.y = workArea.y;
  if (edge === "bottom") snapped.y = workArea.y + workArea.height - frame.height;
  return makeDockAnchor(edge, snapped, scaleFactor);
}

export function makeDockAnchor(edge: FloatingDockEdge, frame: DockRect, scaleFactor: number): DockAnchor {
  const thickness = 12 * scaleFactor;
  const vertical = edge === "left" || edge === "right";
  const length = vertical
    ? frame.height
    : Math.min(frame.width, Math.max(40 * scaleFactor, Math.min(92 * scaleFactor, frame.width * 0.45)));
  const lip = vertical ? {
    x: edge === "left" ? frame.x : frame.x + frame.width - thickness,
    y: frame.y + (frame.height - length) / 2, width: thickness, height: length,
  } : {
    x: frame.x + (frame.width - length) / 2,
    y: edge === "top" ? frame.y : frame.y + frame.height - thickness, width: length, height: thickness,
  };
  return { edge, frame, lip, scaleFactor };
}

export interface DockPorts {
  geometry(): Promise<DockGeometry>;
  pointer(): Promise<{ x: number; y: number; leftButtonDown: boolean }>;
  frame(rect: DockRect): Promise<void>;
  persist(point: { x: number; y: number }): void;
  present(value: DockPresentation): void;
  reducedMotion(): boolean;
  prepareCompact?(anchor: DockAnchor): void | Promise<void>;
  prepareReveal?(): void | Promise<void>;
  beforeNativeReveal?(): Promise<() => void>;
  startDrag(): Promise<boolean>;
  report(error: unknown): void;
  timer?(callback: () => void, delay: number): ReturnType<typeof setTimeout>;
  cancelTimer?(timer: ReturnType<typeof setTimeout>): void;
}

export function createFloatingEdgeDockController(ports: DockPorts) {
  let state = { ...FREE_DOCK_PRESENTATION };
  let disposed = false;
  let generation = 0;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let frameTail = Promise.resolve();
  let nativeDepth = 0;
  let suspended = false;
  let resizing = 0;
  let dragging = false;
  let dragDeadline = 0;
  let pointerInside = false;
  let revealing = false;
  const setTimer = ports.timer ?? setTimeout;
  const clearTimer = ports.cancelTimer ?? clearTimeout;

  function cancel() {
    generation += 1;
    if (timer !== null) clearTimer(timer);
    timer = null;
    return generation;
  }
  function publish(next: DockPresentation) {
    if (disposed) return;
    state = next;
    ports.present(next);
  }
  function later(delay: number, callback: () => void | Promise<void>) {
    const token = cancel();
    timer = setTimer(() => {
      timer = null;
      if (!disposed && token === generation) void Promise.resolve(callback()).catch(ports.report);
    }, delay);
  }
  function current(token: number) { return !disposed && token === generation; }
  function frame(rect: DockRect, token: number) {
    const request = frameTail.then(async () => {
      if (!current(token)) return;
      nativeDepth += 1;
      try {
        await ports.frame(rect);
      } catch (error) {
        const fallback = state.anchor?.frame;
        if (current(token) && fallback) {
          // A size write can succeed while the following position write fails.
          // Recover the full input window before dropping the dock presentation.
          await ports.frame(fallback);
          if (current(token)) publish({ ...FREE_DOCK_PRESENTATION });
        }
        throw error;
      } finally { nativeDepth -= 1; }
    });
    frameTail = request.catch(() => {});
    return request;
  }
  const blocked = () => disposed || suspended || resizing > 0 || dragging;

  async function detach() {
    const token = cancel();
    const anchor = state.anchor;
    if (anchor) {
      await frame(anchor.frame, token);
      if (current(token)) publish({ ...FREE_DOCK_PRESENTATION });
    }
  }
  async function settle() {
    if (blocked() || state.anchor) return;
    const token = cancel();
    const geometry = await ports.geometry();
    if (!current(token) || blocked()) return;
    const anchor = resolveDockAnchor(geometry);
    if (!anchor) { ports.persist(geometry.frame); return; }
    // A verified pointer read prevents hiding during an OS-owned mouse drag.
    const pointer = await ports.pointer();
    if (!current(token) || blocked() || pointer.leftButtonDown) return;
    await frame(anchor.frame, token);
    if (!current(token)) return;
    publish({ anchor, collapsed: false, compact: false, railReady: false, motion: "expand" });
    ports.persist(anchor.frame);
    pointerInside = containsDockPoint(anchor.frame, pointer);
    if (!pointerInside) scheduleHide();
  }
  function scheduleHide() {
    if (blocked() || !state.anchor || state.compact || state.collapsed || pointerInside) return;
    later(450, collapse);
  }
  async function collapse() {
    if (blocked() || !state.anchor || pointerInside) return;
    const token = cancel();
    const pointer = await ports.pointer();
    if (!current(token) || blocked() || containsDockPoint(state.anchor.frame, pointer)) return;
    if (pointer.leftButtonDown) { later(80, collapse); return; }
    publish({ ...state, collapsed: true, railReady: false, motion: ports.reducedMotion() ? "none" : "collapse" });
    later(ports.reducedMotion() ? 0 : 170, async () => {
      const anchor = state.anchor;
      if (!anchor || !state.collapsed || blocked()) return;
      const finish = generation;
      await frame(anchor.lip, finish);
      if (!current(finish)) return;
      // Native bounds and WebKit viewport settle independently. Keep the quota
      // node mounted but invisible until the narrow viewport has painted; fading
      // it in before resizing displays it twice across two coordinate systems.
      publish({ ...state, compact: true, motion: "none" });
      if (pointerInside) { await reveal(); return; }
      try {
        await ports.prepareCompact?.(anchor);
        if (current(finish)) publish({ ...state, railReady: true });
      } catch (error) {
        if (!current(finish)) return;
        await frame(anchor.frame, finish);
        if (current(finish)) publish({ ...FREE_DOCK_PRESENTATION });
        throw error;
      }
    });
  }
  async function reveal() {
    if (disposed || !state.anchor || resizing > 0 || revealing) return;
    revealing = true;
    const token = cancel();
    let restorePaint: (() => void) | undefined;
    try {
      if (state.compact) {
        const live = await ports.geometry();
        if (!current(token) || !state.anchor) return;
        const stillAttached = resolveDockAnchor({ ...live, frame: state.anchor.frame });
        if (live.scaleFactor !== state.anchor.scaleFactor || stillAttached?.edge !== state.anchor.edge) {
          await recoverDisplayGeometry();
          return;
        }
        // WebKit may display its old narrow backing surface at the newly moved
        // window origin. Fade that surface out before any native resize occurs.
        restorePaint = await ports.beforeNativeReveal?.();
        if (!current(token) || !state.anchor) return;
        await frame(state.anchor.frame, token);
        if (!current(token)) return;
        publish({ ...state, compact: false, motion: "none" });
        await ports.prepareReveal?.();
        if (!current(token)) return;
      }
      publish({ ...state, collapsed: false, railReady: false, motion: ports.reducedMotion() ? "none" : "expand" });
      if (!pointerInside) scheduleHide();
    } catch (error) {
      if (current(token) && state.anchor) {
        if (state.compact) await frame(state.anchor.frame, token);
        if (current(token)) publish({ ...FREE_DOCK_PRESENTATION });
      }
      throw error;
    } finally {
      restorePaint?.();
      revealing = false;
    }
  }
  function hover(inside: boolean) {
    pointerInside = inside;
    if (blocked() || nativeDepth > 0 || !state.anchor) return;
    if (inside) {
      if (state.collapsed) void reveal().catch(ports.report);
      else cancel();
    } else scheduleHide();
  }
  async function pollDrag() {
    if (disposed || !dragging) return;
    const token = generation;
    try {
      const pointer = await ports.pointer();
      if (!current(token) || !dragging) return;
      if (!pointer.leftButtonDown) {
        dragging = false;
        await settle();
      } else if (Date.now() < dragDeadline) {
        later(60, pollDrag);
      } else {
        dragging = false;
      }
    } catch (error) {
      dragging = false;
      ports.report(error);
    }
  }
  async function startDrag() {
    dragging = true;
    await detach();
    if (disposed) return;
    dragDeadline = Date.now() + 120_000;
    // The native drag command may resolve before mouse-up. Poll only for this
    // active gesture (single-flight, 60ms); no idle mouse-position polling.
    later(60, pollDrag);
    try { await ports.startDrag(); } catch (error) { ports.report(error); }
  }
  async function recoverDisplayGeometry() {
    const anchor = state.anchor;
    if (!anchor) return;
    const token = cancel();
    const live = await ports.geometry();
    if (!current(token)) return;
    const area = live.workArea;
    const width = Math.min(area.width, anchor.frame.width / anchor.scaleFactor * live.scaleFactor);
    const height = Math.min(area.height, anchor.frame.height / anchor.scaleFactor * live.scaleFactor);
    const offsetX = state.compact ? (anchor.lip.x - anchor.frame.x) / anchor.scaleFactor * live.scaleFactor : 0;
    const offsetY = state.compact ? (anchor.lip.y - anchor.frame.y) / anchor.scaleFactor * live.scaleFactor : 0;
    let x = Math.min(Math.max(live.frame.x - offsetX, area.x), area.x + area.width - width);
    let y = Math.min(Math.max(live.frame.y - offsetY, area.y), area.y + area.height - height);
    if (anchor.edge === "left") x = area.x;
    if (anchor.edge === "right") x = area.x + area.width - width;
    if (anchor.edge === "top") y = area.y;
    if (anchor.edge === "bottom") y = area.y + area.height - height;
    const restored = { x, y, width, height };
    await frame(restored, token);
    if (!current(token)) return;
    publish({ ...FREE_DOCK_PRESENTATION });
    ports.persist(restored);
    if (!blocked()) later(120, settle);
  }
  return {
    state: () => state,
    initialize() { later(350, settle); },
    hover,
    reveal,
    startDrag,
    async suspend(value: boolean) {
      suspended = value;
      if (value) await detach(); else later(100, settle);
    },
    async beforeResize() {
      resizing += 1;
      await detach();
    },
    afterResize() {
      resizing = Math.max(0, resizing - 1);
      if (dragging) later(60, pollDrag);
      else if (!blocked()) later(100, settle);
    },
    moved() {
      if (dragging) return;
      if (state.anchor) {
        // Display/work-area changes are resolved from live geometry instead of
        // persisting an off-screen handle as the user's normal window position.
        void recoverDisplayGeometry().catch(ports.report);
      } else if (!blocked()) later(180, settle);
    },
    interactionEnded() { if (!pointerInside) scheduleHide(); },
    dispose() { disposed = true; cancel(); },
  };
}
