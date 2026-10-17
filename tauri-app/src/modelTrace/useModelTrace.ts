import { useCallback, useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { desktopPlatform } from "../platform/desktop";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import { readSnapshot } from "./client";
import type { TraceSnapshot } from "./types";

export function useModelTrace(active = true) {
  const [snapshot, setSnapshot] = useState<TraceSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const revision = useRef(0);
  const refresh = useCallback(async () => {
    const request = ++revision.current;
    try { const value = await readSnapshot(); if (request === revision.current) {setSnapshot(value); setError(null);} }
    catch (reason) { if (request === revision.current) {setSnapshot(null);setError(String(reason));} }
  }, []);
  useEffect(() => {
    if (!active) return;
    let disposed = false;
    const cleanup: (() => void)[] = [];
    const add = (fn: () => void) => disposed ? fn() : cleanup.push(fn);
    if (isTauriRuntimeAvailable()) {
      void listen("modeltrace-updated", () => void refresh()).then(add).catch(() => {});
      void desktopPlatform.onCodexHomeSourceChanged(() => {
        revision.current++; setSnapshot(null); void refresh();
      }).then(result => { if (result.ok) add(result.unlisten); });
    }
    void refresh();
    const timer = setInterval(() => void refresh(), 5_000);
    return () => { disposed = true; revision.current++; clearInterval(timer); cleanup.forEach(fn => fn()); };
  }, [active, refresh]);
  return {snapshot, error, refresh};
}
