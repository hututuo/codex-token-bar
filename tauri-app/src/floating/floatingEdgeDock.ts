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
  probe?(phase: string, state: DockPresentation): void;
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
  let guiding = false;
  let guidePointer: { x: number; y: number; leftButtonDown: boolean } | null = null;
  const readPointer = () => guidePointer ? Promise.resolve(guidePointer) : ports.pointer();
  const persist = (point: { x: number; y: number }) => { if (!guiding) ports.persist(point); };
  let resizing = 0;
  let dragging = false;
  let dragRevision = 0;
  let dragDeadline = 0;
  let pointerInside = false;
  let revealing = false;
  let heldOpen = false;
  let resizingAnchor: DockAnchor | null = null;
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
    resizingAnchor = null;
    if (anchor) {
      await frame(anchor.frame, token);
      if (current(token)) publish({ ...FREE_DOCK_PRESENTATION });
    }
  }
  async function settle() {
    if (blocked() || heldOpen || state.anchor) return;
    const token = cancel();
    const geometry = await ports.geometry();
    if (!current(token) || blocked()) return;
    const anchor = resolveDockAnchor(geometry);
    if (!anchor) { persist(geometry.frame); return; }
    // A verified pointer read prevents hiding during an OS-owned mouse drag.
    const pointer = await readPointer();
    if (!current(token) || blocked() || pointer.leftButtonDown) return;
    await frame(anchor.frame, token);
    if (!current(token)) return;
    publish({ anchor, collapsed: false, compact: false, railReady: false, motion: "expand" });
    persist(anchor.frame);
    pointerInside = containsDockPoint(anchor.frame, pointer);
    if (!pointerInside) scheduleHide();
  }
  function scheduleHide() {
    if (blocked() || heldOpen || !state.anchor || state.compact || state.collapsed || pointerInside) return;
    later(450, collapse);
  }
  async function collapse() {
    if (blocked() || heldOpen || !state.anchor || pointerInside) return;
    const token = cancel();
    const pointer = await readPointer();
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
    try {
      if (state.compact) {
        const live = await ports.geometry();
        if (!current(token) || !state.anchor) return;
        const stillAttached = resolveDockAnchor({ ...live, frame: state.anchor.frame });
        if (live.scaleFactor !== state.anchor.scaleFactor || stillAttached?.edge !== state.anchor.edge) {
          await recoverDisplayGeometry();
          return;
        }
        // Keep the existing rail visible while restoring the native clip. The
        // shell starts growing before only its quota contents fade away.
        await frame(state.anchor.frame, token);
        if (!current(token)) return;
        publish({ ...state, compact: false, motion: "none" });
        await ports.prepareReveal?.();
        if (!current(token)) return;
        // DOM enter/leave delivery can be noisy while a native child window is
        // being repositioned. Verify the real desktop pointer after the native
        // reveal boundary, matching the macOS tracking path's pointer check.
        try {
          const pointer = await readPointer();
          if (current(token) && state.anchor) pointerInside = containsDockPoint(state.anchor.frame, pointer);
        } catch (error) {
          ports.report(error);
        }
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
      revealing = false;
    }
  }
  function hover(inside: boolean) {
    if (!guiding) applyHover(inside);
  }
  function applyHover(inside: boolean) {
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
      const pointer = await readPointer();
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
    if (disposed || suspended || dragging) return;
    const attempt = ++dragRevision;
    dragging = true;
    try {
      await detach();
      if (disposed || suspended || attempt !== dragRevision) return;
      dragDeadline = Date.now() + 120_000;
      // The native drag command may resolve before mouse-up. Poll only for this
      // active gesture (single-flight, 60ms); no idle mouse-position polling.
      later(60, pollDrag);
      if (!await ports.startDrag() && attempt === dragRevision && !disposed && !suspended) {
        dragging = false;
        later(100, settle);
      }
    } catch (error) {
      // Detaching is part of drag preparation too. A failed frame write must
      // not leave a phantom drag with no native gesture or mouse-up poll.
      if (attempt === dragRevision) {
        dragging = false;
        cancel();
        if (!disposed && !suspended) later(100, settle);
      }
      throw error;
    }
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
    persist(restored);
    if (!blocked()) later(120, settle);
  }
  return {
    state: () => state,
    isGuiding: () => guiding,
    async beginGuide(point: { x: number; y: number }) {
      guiding = true; guidePointer = { ...point, leftButtonDown: false };
      heldOpen = false; suspended = false;
      await detach();
    },
    guideHover(point: { x: number; y: number }) {
      if (!guiding) return;
      guidePointer = { ...point, leftButtonDown: false };
      const area = state.anchor ? (state.compact ? state.anchor.lip : state.anchor.frame) : null;
      applyHover(area ? containsDockPoint(area, point) : false);
    },
    async guideBeginDrag() { dragging = true; await detach(); },
    async guideEndDrag() { dragging = false; await settle(); },
    async guideDetach() { await detach(); },
    endGuide() { cancel(); guiding = false; guidePointer = null; dragging = false; },
    initialize() { later(350, settle); },
    hover,
    reveal,
    startDrag,
    async suspend(value: boolean) {
      suspended = value;
      if (value) { dragRevision++; dragging = false; await detach(); }
      else later(100, settle);
    },
    async holdOpen(value: boolean) {
      heldOpen = value;
      if (value) {
        cancel();
        if (state.collapsed) await reveal();
      } else scheduleHide();
    },
    async beforeResize() {
      resizing += 1;
      if (state.anchor && !suspended && !dragging) {
        resizingAnchor = state.anchor;
        const token = cancel();
        if (state.compact) await frame(state.anchor.frame, token);
        if (current(token)) publish({ ...state, collapsed: false, compact: false, railReady: false, motion: "none" });
      } else await detach();
    },
    afterResize() {
      resizing = Math.max(0, resizing - 1);
      if (resizing > 0) return;
      const anchor = resizingAnchor;
      resizingAnchor = null;
      if (anchor && !blocked()) {
        const token = cancel();
        void ports.geometry().then(live => {
          if (!current(token) || blocked()) return;
          publish({ anchor: makeDockAnchor(anchor.edge, live.frame, live.scaleFactor),
            collapsed: false, compact: false, railReady: false, motion: "none" });
          scheduleHide();
        }).catch(ports.report);
      } else if (dragging) later(60, pollDrag);
      else if (!blocked()) later(100, settle);
    },
    moved() {
      if (dragging || guiding) return;
      if (state.anchor) {
        // Display/work-area changes are resolved from live geometry instead of
        // persisting an off-screen handle as the user's normal window position.
        void recoverDisplayGeometry().catch(ports.report);
      } else if (!blocked()) later(180, settle);
    },
    interactionEnded() { if (!pointerInside) scheduleHide(); },
    async runRightEdgeProbe(cycles = 8) {
      const original = await ports.geometry();
      const wasGuiding = guiding;
      guiding = true;
      const width = original.frame.width;
      const height = original.frame.height;
      const area = original.workArea;
      const full = {
        x: area.x + area.width - width,
        y: Math.min(Math.max(original.frame.y, area.y), area.y + area.height - height),
        width,
        height,
      };
      const anchor = makeDockAnchor("right", full, original.scaleFactor);
      const token = cancel();
      const wait = (milliseconds: number) => new Promise<void>(resolve => setTimeout(resolve, milliseconds));
      try {
        publish({ anchor, collapsed: false, compact: false, railReady: false, motion: "none" });
        await frame(anchor.frame, token);
        ports.probe?.("attached", state);
        for (let cycle = 0; cycle < Math.max(1, cycles); cycle += 1) {
          publish({ ...state, collapsed: true, compact: false, railReady: false, motion: "none" });
          ports.probe?.(`cycle-${cycle}-collapse-css`, state);
          await frame(anchor.lip, token);
          publish({ ...state, compact: true, railReady: false, motion: "none" });
          await ports.prepareCompact?.(anchor);
          ports.probe?.(`cycle-${cycle}-compact`, state);
          await wait(34);

          await frame(anchor.frame, token);
          publish({ ...state, compact: false, collapsed: true, railReady: false, motion: "none" });
          await ports.prepareReveal?.();
          ports.probe?.(`cycle-${cycle}-pre-reveal`, state);
          publish({ ...state, collapsed: false, railReady: false, motion: "expand" });
          ports.probe?.(`cycle-${cycle}-revealing`, state);
          await wait(320);
          ports.probe?.(`cycle-${cycle}-expanded`, state);
        }
      } finally {
        await frame(original.frame, token);
        publish({ ...FREE_DOCK_PRESENTATION });
        ports.probe?.("restored", state);
        guiding = wasGuiding;
      }
    },
    dispose() { disposed = true; dragRevision++; dragging = false; cancel(); },
  };
}
