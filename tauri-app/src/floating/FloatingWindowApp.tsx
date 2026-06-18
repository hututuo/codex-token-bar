import { type CSSProperties, useEffect, useState } from "react";
import { readAppSettings } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
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
  const { snapshot } = useCompactPanelData({
    snapshotIntervalMs: 500,
    quotaInitialDelayMs: 8_000,
    quotaIntervalMs: 180_000,
  });
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

  function closeFloatingWindow() {
    void desktopPlatform.hideFloatingWindow().then((visible) => {
      if (!visible) {
        void desktopPlatform.notifyFloatingWindowHidden();
      }
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
