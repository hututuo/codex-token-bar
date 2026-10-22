import type { SidebarMode } from "./model";

/** One queue per rail, deduplicated across data renders and explicit environment checks. */
export function createSidebarNativeCoordinator(
  apply: (mode: SidebarMode, showsFiveHour: boolean, refreshGeometry: boolean, requestId: number, expandedHeight?: number) => Promise<unknown>,
  report: (error: unknown | null) => void,
) {
  let enabled = false;
  let epoch = 0;
  let latest = { mode: "rest" as SidebarMode, showsFiveHour: false, expandedHeight: undefined as number | undefined };
  let accepted = "";
  let pending = false;
  let refresh = false;
  let running = false;
  let serial = Date.now() * 1000;
  let activeRequest = 0;
  let failedRequest = 0;
  let completedRequest = 0;
  const key = () => `${latest.mode}:${latest.showsFiveHour}:${latest.expandedHeight ?? ""}`;
  async function drain() {
    if (running) return;
    running = true;
    while (pending && enabled) {
      pending = false;
      if (!refresh && accepted === key()) continue;
      const requestEpoch = epoch;
      const requestKey = key();
      const requestId = ++serial;
      activeRequest = requestId;
      const { mode, showsFiveHour, expandedHeight } = latest;
      const refreshGeometry = refresh; refresh = false;
      try { await (expandedHeight === undefined ? apply(mode, showsFiveHour, refreshGeometry, requestId) : apply(mode, showsFiveHour, refreshGeometry, requestId, expandedHeight)); if (enabled && epoch === requestEpoch && failedRequest !== requestId) { accepted = requestKey; report(null); } }
      catch (error) { if (enabled && epoch === requestEpoch) { accepted = ""; report(error); } }
    }
    running = false;
  }
  return {
    complete(requestId: number, error: string | null) {
      if (!enabled || requestId !== activeRequest) return;
      if (error !== null) { failedRequest = requestId; accepted = ""; completedRequest = 0; report(error); }
      else completedRequest = requestId;
    },
    isSettled() { return enabled && activeRequest !== 0 && completedRequest === activeRequest && failedRequest !== activeRequest; },
    update(mode: SidebarMode, showsFiveHour = false, expandedHeight?: number) { latest = { mode, showsFiveHour, expandedHeight: expandedHeight !== undefined && Number.isFinite(expandedHeight) ? Math.max(192, Math.min(4096, Math.ceil(expandedHeight))) : undefined }; if (enabled) { pending = true; void drain(); } },
    refresh() { refresh = true; if (enabled) { pending = true; void drain(); } },
    setEnabled(value: boolean) {
      if (enabled === value) return;
      enabled = value; epoch++; accepted = ""; activeRequest = 0; completedRequest = 0;
      pending = value;
      if (value) void drain();
    },
  };
}
