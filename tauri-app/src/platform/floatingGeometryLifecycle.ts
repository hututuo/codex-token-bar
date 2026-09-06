import type { DockRect } from "../floating/floatingEdgeDock";

interface GeometryLifecycle {
  beforeResize(): Promise<void>;
  afterResize(): void;
}
let owner: GeometryLifecycle | null = null;
let depth = 0;
let quietUntil = 0;
let tail = Promise.resolve();
const settledListeners = new Set<(position: { x: number; y: number }) => void>();

export function registerFloatingGeometryLifecycle(value: GeometryLifecycle) {
  owner = value;
  return () => { if (owner === value) owner = null; };
}
export function floatingGeometryLifecycle() { return owner; }
export function isFloatingGeometryTransient() { return depth > 0 || Date.now() < quietUntil; }

export async function runFloatingGeometryChange(action: () => Promise<void>) {
  const request = tail.then(async () => {
    depth += 1;
    try { await action(); } finally {
      depth -= 1;
      quietUntil = Date.now() + 250;
    }
  });
  tail = request.catch(() => {});
  return request;
}

export function publishFloatingSettledPosition(frame: Pick<DockRect, "x" | "y">) {
  for (const listener of settledListeners) listener({ x: frame.x, y: frame.y });
}
export function onFloatingSettledPosition(listener: (position: { x: number; y: number }) => void) {
  settledListeners.add(listener);
  return () => { settledListeners.delete(listener); };
}
