import { useEffect, useState } from "react";
import { recordStartupEvent } from "../../api/client";

export function useDashboardPageLifecycle() {
  const [summaryReady] = useState(true);
  const [analyticsReady, setAnalyticsReady] = useState(false);

  useEffect(() => {
    void recordStartupEvent("dashboard summary ui ready");
  }, []);

  useEffect(() => {
    if (!summaryReady) {
      return;
    }

    let cancelled = false;
    const reveal = () => {
      if (!cancelled) {
        setAnalyticsReady(true);
        void recordStartupEvent("dashboard analytics ui ready");
      }
    };
    const schedule = scheduleAfterFirstPaint(reveal);

    return () => {
      cancelled = true;
      schedule.cancel();
    };
  }, [summaryReady]);

  return {
    analyticsReady,
    openProviderRepair,
    summaryReady,
  };
}

function openProviderRepair() {
  document.getElementById("provider-repair")?.scrollIntoView({
    behavior: "smooth",
    block: "start",
  });
}

function scheduleAfterFirstPaint(callback: () => void) {
  let cancelled = false;
  queueMicrotask(() => {
    if (!cancelled) {
      callback();
    }
  });

  return {
    cancel: () => {
      cancelled = true;
    },
  };
}
