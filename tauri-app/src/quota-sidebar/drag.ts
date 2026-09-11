/** Buttons retain their complete click targets; the remaining rail is draggable. */
export function isSidebarDragTarget(target: Element): boolean {
  return target.closest("button,a,input,select,textarea,[role=button]") === null;
}

/** The mounted rail uses this owner to invalidate late drag results after disable. */
export function createSidebarDragSession(run: () => Promise<boolean>, done: (dragged: boolean) => void, report: (error: unknown) => void) {
  let active = false;
  let enabled = false;
  let epoch = 0;
  return {
    get active() { return active; },
    get epoch() { return epoch; },
    isCurrent(value: number) { return enabled && epoch === value; },
    setEnabled(value: boolean) { if (enabled !== value) { enabled = value; epoch++; } },
    start() {
      if (active || !enabled) return false;
      active = true;
      const generation = epoch;
      void run().then(dragged => {
        active = false;
        if (enabled && epoch === generation) done(dragged);
      }, error => {
        active = false;
        if (enabled && epoch === generation) { report(error); done(false); }
      });
      return true;
    },
  };
}
