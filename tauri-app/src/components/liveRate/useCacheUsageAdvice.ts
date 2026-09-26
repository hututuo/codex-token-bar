import { useSyncExternalStore } from "react";
import type { CacheUsageAdvice } from "../../types/live";
import { cacheAdviceID, cacheAdviceWarning } from "./cacheAdvicePresentation";

const enabledKey = "cacheHitAdviceEnabled";
const dismissedKey = "cacheHitAdviceDismissed";
const changed = "cache-hit-advice-setting";
function read(key: string) {
  try { return localStorage.getItem(key); } catch { return null; }
}
function subscribe(update: () => void) {
  window.addEventListener("storage", update);
  window.addEventListener(changed, update);
  return () => { window.removeEventListener("storage", update); window.removeEventListener(changed, update); };
}
function write(key: string, value: string) {
  try { localStorage.setItem(key, value); } catch { return; }
  window.dispatchEvent(new Event(changed));
}

/** One preference and per-request dismissal shared by all three sidebar levels. */
export function useCacheUsageAdvice(advice?: CacheUsageAdvice | null, available = true) {
  const enabled = useSyncExternalStore(subscribe, () => read(enabledKey) !== "false", () => true);
  const dismissedID = useSyncExternalStore(subscribe, () => read(dismissedKey) ?? "", () => "");
  const warning = cacheAdviceWarning(advice, enabled && available, dismissedID);
  return { enabled, warning,
    setEnabled: (value: boolean) => write(enabledKey, String(value)),
    dismiss: () => { if (advice) write(dismissedKey, cacheAdviceID(advice)); },
  };
}
