import { useEffect, useRef, type Dispatch } from "react";
import type { CacheUsageAdvice } from "../types/live";
import type { SidebarAction } from "./model";
import { cacheAdviceID } from "../components/liveRate/cacheAdvicePresentation";

/** Reveal only the summary, once per request; never open a detail or steal focus. */
export function useSidebarCacheAdvice(warning: CacheUsageAdvice | null, dispatch: Dispatch<SidebarAction>, dragging = false) {
  const id = warning ? cacheAdviceID(warning) : null;
  const presented = useRef<string | null>(null);
  useEffect(() => {
    if (!id) { dispatch({ type: "cache-advice", id: null }); return; }
    if (dragging || presented.current === id) return;
    presented.current = id;
    dispatch({ type: "cache-advice", id });
  }, [id, dispatch, dragging]);
}
