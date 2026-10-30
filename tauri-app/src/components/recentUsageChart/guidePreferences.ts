const HIDDEN_KEY = "recentChartInteractionGuideHidden";
const DISMISSED_KEY = "recentChartInteractionGuideDismissed";
const CHANGE_EVENT = "recent-chart-guide-preferences-changed";

export function chartGuideHidden(): boolean {
  try { return typeof window !== "undefined" && window.localStorage.getItem(HIDDEN_KEY) === "true"; }
  catch { return false; }
}

export function setChartGuideHidden(hidden: boolean): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(HIDDEN_KEY, String(hidden));
    if (!hidden) window.localStorage.setItem(DISMISSED_KEY, "false");
  } catch { /* Current-window visibility still works when storage is blocked. */ }
  window.dispatchEvent(new window.Event(CHANGE_EVENT));
}

export function subscribeChartGuidePreferences(changed: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const onStorage = (event: StorageEvent) => {
    if (event.key === HIDDEN_KEY || event.key === DISMISSED_KEY || event.key === null) changed();
  };
  window.addEventListener(CHANGE_EVENT, changed);
  window.addEventListener("storage", onStorage);
  return () => {
    window.removeEventListener(CHANGE_EVENT, changed);
    window.removeEventListener("storage", onStorage);
  };
}
