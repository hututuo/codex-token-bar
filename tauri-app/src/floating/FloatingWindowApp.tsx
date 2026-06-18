import { type CSSProperties, useEffect, useState } from "react";
import { readAccountQuota, readAppSettings, readFloatingPanelSnapshot } from "../api/client";
import { emptyFloatingPanelSnapshot } from "../api/fallback";
import { desktopPlatform } from "../platform/desktop";
import type { FloatingPanelSnapshot } from "../types/dashboard";
import { compactQuotaLabel } from "../utils/quota";
import {
  FLOATING_BASE_HEIGHT,
  FLOATING_BASE_WIDTH,
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
  type FloatingWindowSettings,
} from "./floatingSettings";
import { FloatingPanelSurface } from "./FloatingPanelPreview";
import { useFloatingWindowPlacement } from "./useFloatingWindowPlacement";

export function FloatingWindowApp() {
  const [snapshot, setSnapshot] = useState<FloatingPanelSnapshot>(emptyFloatingPanelSnapshot);
  const [settings, setSettings] = useState<FloatingWindowSettings>(DEFAULT_FLOATING_SETTINGS);
  useFloatingWindowPlacement();

  useEffect(() => {
    document.documentElement.classList.add("floating-document");
    return () => document.documentElement.classList.remove("floating-document");
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onFloatingSettingsChanged((payload) => {
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
    let cancelled = false;

    void readAppSettings().then((settings) => {
      if (!cancelled && settings !== null) {
        setSettings(sanitizeFloatingSettings(settings.floatingWindow));
      }
    });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    void desktopPlatform.resizeFloatingWindow(
      FLOATING_BASE_WIDTH * settings.scale,
      FLOATING_BASE_HEIGHT * settings.scale,
    );
  }, [settings.scale]);

  useEffect(() => {
    let cancelled = false;
    let snapshotInFlight = false;

    async function refreshSnapshot() {
      if (snapshotInFlight) {
        return;
      }

      snapshotInFlight = true;
      try {
        const next = await readFloatingPanelSnapshot();
        if (!cancelled) {
          setSnapshot((current) => ({
            ...next,
            fiveHourLabel: current.fiveHourLabel,
            sevenDayLabel: current.sevenDayLabel,
          }));
        }
      } finally {
        snapshotInFlight = false;
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
    let quotaInFlight = false;

    async function refreshQuota() {
      if (quotaInFlight) {
        return;
      }

      quotaInFlight = true;
      try {
        const quota = await readAccountQuota();
        if (!cancelled && quota !== null) {
          setSnapshot((current) => ({
            ...current,
            fiveHourLabel: compactQuotaLabel(quota.quota.fiveHour),
            sevenDayLabel: compactQuotaLabel(quota.quota.sevenDay),
          }));
        }
      } finally {
        quotaInFlight = false;
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
    void desktopPlatform.hideFloatingWindow().then(() => {
      void desktopPlatform.notifyFloatingWindowHidden();
    });
  }

  function startWindowDrag() {
    void desktopPlatform.startFloatingWindowDrag();
  }

  const shellStyle = {
    "--floating-card-opacity": settings.opacity.toFixed(2),
    "--floating-scale": settings.scale.toFixed(2),
  } as CSSProperties;

  return (
    <main className="floating-window-shell" style={shellStyle}>
      <FloatingPanelSurface
        snapshot={snapshot}
        unreadEffect={settings.unreadEffect}
        onClose={closeFloatingWindow}
        onDragStart={startWindowDrag}
      />
    </main>
  );
}
