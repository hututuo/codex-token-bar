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

  const gradientBackground =
    settings.gradientType === "radial"
      ? `radial-gradient(circle at 18% 10%, ${settings.gradientStart}, ${settings.gradientEnd})`
      : `linear-gradient(${settings.gradientDirection}, ${settings.gradientStart}, ${settings.gradientEnd})`;
  const effectColor = effectColorFromGradient(settings.gradientStart, settings.gradientEnd);
  const shellStyle = {
    "--floating-card-opacity": settings.opacity.toFixed(2),
    "--floating-scale": settings.scale.toFixed(2),
    "--floating-gradient-background": gradientBackground,
    "--floating-effect-color": effectColor.hex,
    "--floating-effect-rgb": effectColor.rgb,
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

function effectColorFromGradient(start: string, end: string): { hex: string; rgb: string } {
  const mixed = mixRgb(parseHexColor(start), parseHexColor(end), 0.58);
  const accent = {
    r: Math.max(0, Math.round(mixed.r * 0.72)),
    g: Math.max(0, Math.round(mixed.g * 0.82)),
    b: Math.min(255, Math.round(mixed.b * 1.08 + 18)),
  };
  return {
    hex: rgbToHex(accent),
    rgb: `${accent.r}, ${accent.g}, ${accent.b}`,
  };
}

function parseHexColor(value: string): { r: number; g: number; b: number } {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value.trim());
  if (!match) {
    return { r: 31, g: 110, b: 210 };
  }
  return {
    r: Number.parseInt(match[1], 16),
    g: Number.parseInt(match[2], 16),
    b: Number.parseInt(match[3], 16),
  };
}

function mixRgb(
  start: { r: number; g: number; b: number },
  end: { r: number; g: number; b: number },
  endWeight: number,
) {
  const startWeight = 1 - endWeight;
  return {
    r: start.r * startWeight + end.r * endWeight,
    g: start.g * startWeight + end.g * endWeight,
    b: start.b * startWeight + end.b * endWeight,
  };
}

function rgbToHex(color: { r: number; g: number; b: number }): string {
  return `#${[color.r, color.g, color.b].map((channel) => channel.toString(16).padStart(2, "0")).join("")}`;
}
