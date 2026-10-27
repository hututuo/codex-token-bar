import type { SidebarMode } from "./model";

/** One queue per rail, deduplicated across data renders and explicit environment checks. */
export function createSidebarNativeCoordinator(
  apply: (mode: SidebarMode, showsFiveHour: boolean, refreshGeometry: boolean, requestId: number, expandedHeight?: number, compactHeight?: number, settingsPreview?: boolean) => Promise<unknown>,
  report: (error: unknown | null) => void,
) {
  let enabled = false;
  let epoch = 0;
  let latest = { mode: "rest" as SidebarMode, showsFiveHour: false, expandedHeight: undefined as number | undefined, compactHeight: undefined as number | undefined, settingsPreview: false };
  let accepted = "";
  let pending = false;
  let refresh = false;
  let running = false;
  let serial = Date.now() * 1000;
  let activeRequest = 0;
  let failedRequest = 0;
  let completedRequest = 0;
  const key = () => `${latest.mode}:${latest.showsFiveHour}:${latest.expandedHeight ?? ""}:${latest.compactHeight ?? ""}:${latest.settingsPreview}`;
  let activeMode: SidebarMode | null = null;
  let activeKey = "";
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
      activeKey = requestKey;
      const { mode, showsFiveHour, expandedHeight, compactHeight, settingsPreview } = latest;
      activeMode = mode;
      const refreshGeometry = refresh; refresh = false;
      try { await (settingsPreview ? apply(mode, showsFiveHour, refreshGeometry, requestId, expandedHeight, compactHeight, true) : compactHeight !== undefined ? apply(mode, showsFiveHour, refreshGeometry, requestId, expandedHeight, compactHeight) : expandedHeight === undefined ? apply(mode, showsFiveHour, refreshGeometry, requestId) : apply(mode, showsFiveHour, refreshGeometry, requestId, expandedHeight)); if (enabled && epoch === requestEpoch && failedRequest !== requestId) { accepted = requestKey; report(null); } }
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
    isSettled(mode?: SidebarMode) { return enabled && !pending && activeKey === key() && activeRequest !== 0 && completedRequest === activeRequest && failedRequest !== activeRequest && (mode === undefined || (activeMode === mode && latest.mode === mode)); },
    update(mode: SidebarMode, showsFiveHour = false, expandedHeight?: number, compactHeight?: number, settingsPreview = false) { latest = { mode, showsFiveHour, settingsPreview: mode === "detail" && settingsPreview, expandedHeight: expandedHeight !== undefined && Number.isFinite(expandedHeight) ? Math.max(192, Math.min(4096, Math.ceil(expandedHeight))) : undefined, compactHeight: compactHeight !== undefined && Number.isFinite(compactHeight) && compactHeight > 0 ? Math.min(4096, compactHeight) : undefined }; if (enabled) { pending = true; void drain(); } },
    refresh() { refresh = true; if (enabled) { pending = true; void drain(); } },
    setEnabled(value: boolean) {
      if (enabled === value) return;
      enabled = value; epoch++; accepted = ""; activeKey = ""; activeRequest = 0; completedRequest = 0;
      pending = value;
      if (value) void drain();
    },
  };
}
