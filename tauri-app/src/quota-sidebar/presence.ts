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
