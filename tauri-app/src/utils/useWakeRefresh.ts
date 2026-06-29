import { useEffect, useRef } from "react";

export const WAKE_REFRESH_GAP_MS = 2 * 60 * 1000;
const WAKE_REFRESH_CHECK_INTERVAL_MS = 30_000;
const WAKE_REFRESH_COOLDOWN_MS = 30_000;

interface UseWakeRefreshOptions {
  active: boolean;
  onWake: () => void;
}

export function useWakeRefresh({ active, onWake }: UseWakeRefreshOptions) {
  const lastSeenAt = useRef(Date.now());
  const lastWakeRefreshAt = useRef(0);
  const onWakeRef = useRef(onWake);

  useEffect(() => {
    onWakeRef.current = onWake;
  }, [onWake]);

  useEffect(() => {
    if (!active || typeof window === "undefined") {
      lastSeenAt.current = Date.now();
      return;
    }

    const handleWakeCheck = () => {
      const now = Date.now();
      const gapMs = now - lastSeenAt.current;
      lastSeenAt.current = now;
      if (gapMs < WAKE_REFRESH_GAP_MS) {
        return;
      }
      if (now - lastWakeRefreshAt.current < WAKE_REFRESH_COOLDOWN_MS) {
        return;
      }
      lastWakeRefreshAt.current = now;
      onWakeRef.current();
    };

    const interval = window.setInterval(handleWakeCheck, WAKE_REFRESH_CHECK_INTERVAL_MS);
    window.addEventListener("focus", handleWakeCheck);
    window.addEventListener("pageshow", handleWakeCheck);
    document.addEventListener("visibilitychange", handleWakeCheck);

    return () => {
      window.clearInterval(interval);
      window.removeEventListener("focus", handleWakeCheck);
      window.removeEventListener("pageshow", handleWakeCheck);
      document.removeEventListener("visibilitychange", handleWakeCheck);
    };
  }, [active]);
}
