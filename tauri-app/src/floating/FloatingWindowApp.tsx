import { useEffect, useState } from "react";
import { emit } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { mockFloatingPanelSnapshot } from "../api/mock";
import { hideFloatingWindow, readAccountQuota, readFloatingPanelSnapshot } from "../api/client";
import type { FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";
import { FloatingPanelSurface } from "./FloatingPanelPreview";

export function FloatingWindowApp() {
  const [snapshot, setSnapshot] = useState<FloatingPanelSnapshot>(mockFloatingPanelSnapshot);

  useEffect(() => {
    document.documentElement.classList.add("floating-document");
    return () => document.documentElement.classList.remove("floating-document");
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function refreshSnapshot() {
      const next = await readFloatingPanelSnapshot();
      if (!cancelled) {
        setSnapshot((current) => ({
          ...next,
          fiveHourLabel: current.fiveHourLabel,
          sevenDayLabel: current.sevenDayLabel,
        }));
      }
    }

    void refreshSnapshot();
    const interval = window.setInterval(() => {
      void refreshSnapshot();
    }, 500);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function refreshQuota() {
      const quota = await readAccountQuota();
      if (!cancelled) {
        setSnapshot((current) => ({
          ...current,
          fiveHourLabel: compactQuotaLabel(quota.quota.fiveHour),
          sevenDayLabel: compactQuotaLabel(quota.quota.sevenDay),
        }));
      }
    }

    void refreshQuota();
    const interval = window.setInterval(() => {
      void refreshQuota();
    }, 180_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, []);

  function closeFloatingWindow() {
    if (!("__TAURI_INTERNALS__" in window)) {
      return;
    }
    void hideFloatingWindow().then(() => emit("floating-window-hidden"));
  }

  function startWindowDrag() {
    if (!("__TAURI_INTERNALS__" in window)) {
      return;
    }
    void getCurrentWindow().startDragging();
  }

  return (
    <main className="floating-window-shell">
      <FloatingPanelSurface
        snapshot={snapshot}
        onClose={closeFloatingWindow}
        onDragStart={startWindowDrag}
      />
    </main>
  );
}
