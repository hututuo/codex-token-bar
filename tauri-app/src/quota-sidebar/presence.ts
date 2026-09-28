/** Reconcile only while expanded. Native tracking areas can be rebuilt during
 * resizing without delivering a final exit event. Never overlap IPC requests. */
export function monitorSidebarPresence(
  inside: () => Promise<boolean>,
  leave: () => void,
  schedule: (callback: () => void) => () => void = callback => {
    const timer = setTimeout(callback, 250);
    return () => clearTimeout(timer);
  },
) {
  let disposed = false;
  let outsideSamples = 0;
  let cancel = () => {};
  const sample = async () => {
    try {
      const present = await inside();
      if (disposed) return;
      outsideSamples = present ? 0 : outsideSamples + 1;
      if (outsideSamples >= 2) { disposed = true; leave(); return; }
    } catch { outsideSamples = 0; }
    if (!disposed) cancel = schedule(() => { void sample(); });
  };
  cancel = schedule(() => { void sample(); });
  return () => { disposed = true; cancel(); };
}

export interface SidebarPointerState { inside: boolean; clickRevision: number }
/** An auto-revealed notice waits for entry/exit or a NEW outside click. */
export function monitorSidebarReminder(
  sample: () => Promise<SidebarPointerState>, dismiss: () => void,
  schedule: (callback: () => void) => () => void = callback => {
    const timer = setTimeout(callback, 150); return () => clearTimeout(timer);
  },
  pointerEntered: () => boolean = () => false,
) {
  let disposed = false, entered = false, outsideSamples = 0;
  let previousClick: number | undefined;
  let cancel = () => {};
  const poll = async () => {
    try {
      const state = await sample();
      if (disposed) return;
      const clicked = previousClick !== undefined && state.clickRevision !== previousClick;
      previousClick = state.clickRevision;
      entered ||= state.inside || pointerEntered();
      outsideSamples = state.inside ? 0 : outsideSamples + 1;
      if (!state.inside && (clicked || (entered && outsideSamples >= 2))) {
        disposed = true; dismiss(); return;
      }
    } catch { outsideSamples = 0; }
    if (!disposed) cancel = schedule(() => { void poll(); });
  };
  void poll();
  return () => { disposed = true; cancel(); };
}
