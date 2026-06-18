import { type CSSProperties, useEffect, useState } from "react";
import { emit, listen } from "@tauri-apps/api/event";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { mockFloatingPanelSnapshot } from "../api/mock";
import { hideFloatingWindow, readAccountQuota, readFloatingPanelSnapshot } from "../api/client";
import type { FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";
import {
  FLOATING_BASE_HEIGHT,
  FLOATING_BASE_WIDTH,
  FLOATING_SETTINGS_EVENT,
  readFloatingSettings,
  sanitizeFloatingSettings,
  type FloatingWindowSettings,
} from "./floatingSettings";
import { FloatingPanelSurface } from "./FloatingPanelPreview";
import { useFloatingWindowPlacement } from "./useFloatingWindowPlacement";

export function FloatingWindowApp() {
  const [snapshot, setSnapshot] = useState<FloatingPanelSnapshot>(mockFloatingPanelSnapshot);
  const [settings, setSettings] = useState<FloatingWindowSettings>(readFloatingSettings);
  useFloatingWindowPlacement();

  useEffect(() => {
    document.documentElement.classList.add("floating-document");
    return () => document.documentElement.classList.remove("floating-document");
  }, []);

  useEffect(() => {
    if (!("__TAURI_INTERNALS__" in window)) {
      return;
    }

    let disposed = false;
    let unlisten: (() => void) | null = null;

    void listen<FloatingWindowSettings>(FLOATING_SETTINGS_EVENT, ({ payload }) => {
      setSettings(sanitizeFloatingSettings(payload));
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!("__TAURI_INTERNALS__" in window)) {
      return;
    }

    void getCurrentWindow().setSize(
      new LogicalSize(FLOATING_BASE_WIDTH * settings.scale, FLOATING_BASE_HEIGHT * settings.scale),
    );
  }, [settings.scale]);

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

  const shellStyle = {
    "--floating-card-opacity": settings.opacity.toFixed(2),
    "--floating-scale": settings.scale.toFixed(2),
  } as CSSProperties;

  return (
    <main className="floating-window-shell" style={shellStyle}>
      <FloatingPanelSurface
        snapshot={snapshot}
        onClose={closeFloatingWindow}
        onDragStart={startWindowDrag}
      />
    </main>
  );
}
