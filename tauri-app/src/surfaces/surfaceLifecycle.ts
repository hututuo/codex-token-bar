export interface FloatingSurfaceLifecycle {
  active: boolean;
  activationGeneration: number;
  enabled: boolean;
  visible: boolean;
}

export type FloatingSurfaceLifecycleEvent =
  | { type: "enabled"; value: boolean }
  | { type: "visible"; value: boolean };

interface FloatingSurfaceVisibilityObserverOptions {
  onVisible: (visible: boolean) => void;
  readVisible: () => Promise<boolean>;
  subscribe: (handler: (visible: boolean) => void) => Promise<() => void>;
}

export const INITIAL_FLOATING_SURFACE_LIFECYCLE: FloatingSurfaceLifecycle = Object.freeze({
  active: false,
  activationGeneration: 0,
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
    activationGeneration: !current.active && active
      ? current.activationGeneration + 1
      : current.activationGeneration,
    enabled,
    visible,
  };
}

export function statusPanelIsActive(visible: boolean, focused: boolean): boolean {
  return visible && focused;
}

export function observeFloatingSurfaceVisibility({
  onVisible,
  readVisible,
  subscribe,
}: FloatingSurfaceVisibilityObserverOptions): () => void {
  let disposed = false;
  let eventRevision = 0;
  let unlisten: (() => void) | null = null;

  void (async () => {
    try {
      const listener = await subscribe((visible) => {
        eventRevision += 1;
        if (!disposed) {
          onVisible(Boolean(visible));
        }
      });
      if (disposed) {
        listener();
        return;
      }
      unlisten = listener;
    } catch {
      // A direct visibility read still provides a fail-closed startup state.
    }

    if (disposed) {
      return;
    }
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
    }
  })();

  return () => {
    disposed = true;
    unlisten?.();
  };
}
