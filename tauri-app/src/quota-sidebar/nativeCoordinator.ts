import type { SidebarMode } from "./model";

/** One queue per rail, deduplicated across data renders and explicit environment checks. */
export function createSidebarNativeCoordinator(
  apply: (mode: SidebarMode, showsFiveHour: boolean, refreshGeometry: boolean) => Promise<unknown>,
  report: (error: unknown | null) => void,
) {
  let enabled = false;
  let epoch = 0;
  let latest = { mode: "rest" as SidebarMode, showsFiveHour: false };
  let accepted = "";
  let pending = false;
  let refresh = false;
  let running = false;
  const key = () => `${latest.mode}:${latest.showsFiveHour}`;
  async function drain() {
    if (running) return;
    running = true;
    while (pending && enabled) {
      pending = false;
      if (!refresh && accepted === key()) continue;
      const requestEpoch = epoch;
      const requestKey = key();
      const { mode, showsFiveHour } = latest;
      const refreshGeometry = refresh; refresh = false;
      try { await apply(mode, showsFiveHour, refreshGeometry); if (enabled && epoch === requestEpoch) { accepted = requestKey; report(null); } }
      catch (error) { if (enabled && epoch === requestEpoch) report(error); }
    }
    running = false;
  }
  return {
    update(mode: SidebarMode, showsFiveHour = false) { latest = { mode, showsFiveHour }; if (enabled) { pending = true; void drain(); } },
    refresh() { refresh = true; if (enabled) { pending = true; void drain(); } },
    setEnabled(value: boolean) {
      if (enabled === value) return;
      enabled = value; epoch++; accepted = "";
      pending = value;
      if (value) void drain();
    },
  };
}
