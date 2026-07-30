export interface FloatingSurfaceLifecycle {
  active: boolean;
  enabled: boolean;
  visible: boolean;
}

export type FloatingSurfaceLifecycleEvent =
  | { type: "enabled"; value: boolean }
  | { type: "visible"; value: boolean };

interface FloatingSurfaceVisibilityObserverOptions {
  onVisible: (visible: boolean) => void;
  readVisible: () => Promise<boolean>;
  scheduleReconcile?: (
    refresh: () => Promise<void>,
    intervalMs: number,
  ) => () => void;
  subscribe: (
    handler: (visible: boolean) => void,
  ) => Promise<FloatingVisibilitySubscriptionResult>;
}

type FloatingVisibilitySubscriptionResult =
  | { ok: true; unlisten: () => void }
  | { ok: false; error: string };

export const FLOATING_VISIBILITY_RECONCILE_INTERVAL_MS = 30_000;

export const INITIAL_FLOATING_SURFACE_LIFECYCLE: FloatingSurfaceLifecycle = Object.freeze({
  active: false,
  enabled: false,
  visible: false,
});

export function reduceFloatingSurfaceLifecycle(
  current: FloatingSurfaceLifecycle,
  event: FloatingSurfaceLifecycleEvent,
): FloatingSurfaceLifecycle {
  const enabled = event.type === "enabled" ? event.value : current.enabled;
  const visible = event.type === "visible" ? event.value : current.visible;
  if (enabled === current.enabled && visible === current.visible) {
    return current;
  }
  const active = enabled && visible;
  return {
    active,
    enabled,
    visible,
  };
}

export function statusPanelIsActive(visible: boolean): boolean {
  return visible;
}

export function observeFloatingSurfaceVisibility({
  onVisible,
  readVisible,
  scheduleReconcile = scheduleFloatingVisibilityReconciliation,
  subscribe,
}: FloatingSurfaceVisibilityObserverOptions): () => void {
  let disposed = false;
  let eventRevision = 0;
  let reconcileInFlight = false;
  let cancelReconcile: (() => void) | null = null;
  let unlisten: (() => void) | null = null;

  const reconcile = async () => {
    if (disposed || reconcileInFlight) {
      return;
    }
    reconcileInFlight = true;
    const revisionBeforeRead = eventRevision;
    try {
      const visible = await readVisible();
      if (!disposed && eventRevision === revisionBeforeRead) {
        onVisible(Boolean(visible));
      }
    } catch {
      if (!disposed && eventRevision === 0) {
        onVisible(false);
      }
    } finally {
      reconcileInFlight = false;
    }
  };

  void (async () => {
    try {
      const result = await subscribe((visible) => {
        eventRevision += 1;
        if (!disposed) {
          onVisible(Boolean(visible));
        }
      });
      if (disposed) {
        if (result.ok) {
          result.unlisten();
        }
        return;
      }
      if (result.ok) {
        unlisten = result.unlisten;
      } else {
        cancelReconcile = scheduleReconcile(
          reconcile,
          FLOATING_VISIBILITY_RECONCILE_INTERVAL_MS,
        );
      }
    } catch {
      if (!disposed) {
        cancelReconcile = scheduleReconcile(
          reconcile,
          FLOATING_VISIBILITY_RECONCILE_INTERVAL_MS,
        );
      }
    }

    if (disposed) {
      return;
    }
    await reconcile();
  })();

  return () => {
    disposed = true;
    unlisten?.();
    cancelReconcile?.();
  };
}

function scheduleFloatingVisibilityReconciliation(
  refresh: () => Promise<void>,
  intervalMs: number,
): () => void {
  const timer = window.setInterval(() => {
    void refresh();
  }, intervalMs);
  return () => window.clearInterval(timer);
}
