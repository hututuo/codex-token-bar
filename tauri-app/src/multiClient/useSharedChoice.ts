import { useCallback, useEffect, useState } from "react";
import {
  clearPlatformFailure,
  emitPlatformEvent,
  listenToEventResult,
  warnPlatformFailure,
  type Unlisten,
} from "../platform/desktopBridge";
import { isTauriRuntimeAvailable } from "../platform/runtime";

// Storage keys are a persisted format. Native event names are a different
// protocol: Tauri forbids dots. Never rename stored preferences to fix IPC.
export const choiceEvents = {
  dashboard: "multi-client-display-scope-changed",
  sidebar: "multi-client-sidebar-display-scope-changed",
  quota: "multi-client-quota-selection-changed",
} as const;

export function useSharedChoice(key: string, eventName: string, fallback: string) {
  const read = useCallback(() => {
    try { return localStorage.getItem(key) ?? fallback; }
    catch { return fallback; }
  }, [key, fallback]);
  const [choice, setChoice] = useState(() => ({ key, raw: read() }));
  const persist = useCallback((raw: string) => {
    try {
      localStorage.setItem(key, raw);
      clearPlatformFailure(`choice-storage:${key}`);
    } catch (error) {
      // A full/disabled storage area must not break this window's controls.
      warnPlatformFailure(`choice-storage:${key}`, error);
    }
  }, [key]);

  useEffect(() => {
    setChoice({ key, raw: read() });
    let disposed = false;
    let unlisten: Unlisten | undefined;
    const release = (fn: Unlisten) => {
      // Tauri's UnlistenFn is typed void, but its implementation is async.
      try { void Promise.resolve(fn()).catch(error => warnPlatformFailure(`unlisten:${eventName}`, error)); }
      catch (error) { warnPlatformFailure(`unlisten:${eventName}`, error); }
    };
    const update = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail;
      setChoice({ key, raw: typeof detail === "string" ? detail : read() });
    };
    const storage = (event: StorageEvent) => {
      if (event.key !== null && event.key !== undefined && event.key !== key) return;
      setChoice({ key, raw: read() });
    };
    window.addEventListener(key, update);
    window.addEventListener("storage", storage);
    if (isTauriRuntimeAvailable()) {
      void listenToEventResult<string>(eventName, raw => {
        if (disposed || typeof raw !== "string") return;
        persist(raw);
        setChoice({ key, raw });
      }).then(result => {
        if (!result.ok) return; // The bridge has recorded the subscription failure.
        if (disposed) release(result.unlisten);
        else unlisten = result.unlisten;
      });
    }
    return () => {
      disposed = true;
      if (unlisten) release(unlisten);
      window.removeEventListener(key, update);
      window.removeEventListener("storage", storage);
    };
  }, [key, eventName, read, persist]);

  const save = useCallback((raw: string) => {
    persist(raw);
    setChoice({ key, raw });
    // Keep the old DOM event contract while allowing in-memory synchronization
    // when persistence is unavailable. Native receivers never rebroadcast.
    window.dispatchEvent(new window.CustomEvent(key, { detail: raw }));
    void emitPlatformEvent(eventName, `emit:${eventName}`, raw);
  }, [key, eventName, persist]);
  return [choice.key === key ? choice.raw : read(), save] as const;
}
