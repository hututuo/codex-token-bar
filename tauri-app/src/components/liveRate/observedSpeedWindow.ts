import { useSyncExternalStore } from "react";

const storageKey = "observedSpeedWindowMinutes";
const eventName = "observed-speed-window-changed";
export function readObservedSpeedWindow(): 15 | 30 {
  try { return globalThis.localStorage?.getItem(storageKey) === "30" ? 30 : 15; } catch { return 15; }
}
function subscribe(callback: () => void) {
  const onStorage = (event: StorageEvent) => { if (event.key === storageKey) callback(); };
  window.addEventListener(eventName, callback);
  window.addEventListener("storage", onStorage);
  return () => { window.removeEventListener(eventName, callback); window.removeEventListener("storage", onStorage); };
}
export function setObservedSpeedWindow(minutes: 15 | 30) {
  try { localStorage.setItem(storageKey, String(minutes)); } catch { return; }
  window.dispatchEvent(new Event(eventName));
}
export function useObservedSpeedWindow() {
  return [useSyncExternalStore(subscribe, readObservedSpeedWindow, () => 15 as const), setObservedSpeedWindow] as const;
}
