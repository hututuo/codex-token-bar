import { useSyncExternalStore } from "react";
import { invalidateSpeedColors, readSpeedColors, SPEED_PREFERENCES_EVENT } from "./speedDisplay";
const empty: Record<string, string> = {};
function subscribe(notify: () => void) {
  const storage = () => { invalidateSpeedColors(); notify(); };
  window.addEventListener("storage", storage); window.addEventListener(SPEED_PREFERENCES_EVENT, notify);
  return () => { window.removeEventListener("storage", storage); window.removeEventListener(SPEED_PREFERENCES_EVENT, notify); };
}
/** Memoized charts still repaint immediately when the global palette changes. */
export function useSpeedPalette() { return useSyncExternalStore(subscribe, readSpeedColors, () => empty); }
