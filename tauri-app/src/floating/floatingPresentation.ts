import {
  floatingGradientBackground,
  sanitizeFloatingSettings,
} from "./floatingSettings";
import type {
  FloatingContentVisibility,
  FloatingWindowSettings,
} from "../types/dashboard";

/**
 * The floating window and the settings preview are two hosts for one surface.
 * Keep their CSS variables and effect-colour calculation in one pure helper
 * so the preview cannot silently drift from the real window.
 */
export interface FloatingEffectRgb {
  red: number;
  green: number;
  blue: number;
}

export interface FloatingPanelAppearance {
  effectRgb: FloatingEffectRgb;
  style: Record<string, string>;
}

export function floatingPanelAppearance(
  settings: Pick<
    FloatingWindowSettings,
    "opacity" | "scale" | "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType"
  >,
): FloatingPanelAppearance {
  const effectRgb = floatingEffectRgbFromGradient(settings.gradientStart, settings.gradientEnd);
  return {
    effectRgb,
    style: {
      "--floating-card-opacity": settings.opacity.toFixed(2),
      "--floating-scale": settings.scale.toFixed(2),
      "--floating-gradient-background": floatingGradientBackground(settings),
      "--floating-effect-color": floatingEffectHexColor(effectRgb),
      "--floating-effect-rgb": `${effectRgb.red}, ${effectRgb.green}, ${effectRgb.blue}`,
    },
  };
}

/** Normalize visibility at the same boundary for both hosts. */
export function floatingPanelSettingsForVisibility(
  settings: FloatingWindowSettings,
  contentVisibility: FloatingContentVisibility = settings.contentVisibility,
): FloatingWindowSettings {
  return sanitizeFloatingSettings({
    ...settings,
    contentVisibility,
  });
}

export function floatingEffectRgbFromGradient(start: string, end: string): FloatingEffectRgb {
  const mixed = mixRgb(parseHexColor(start), parseHexColor(end), 0.58);
  return {
    red: Math.max(0, Math.round(mixed.red * 0.72)),
    green: Math.max(0, Math.round(mixed.green * 0.82)),
    blue: Math.min(255, Math.round(mixed.blue * 1.08 + 18)),
  };
}

export function floatingEffectHexColor(color: FloatingEffectRgb): string {
  return `#${[color.red, color.green, color.blue]
    .map((channel) => clampColorChannel(channel).toString(16).padStart(2, "0"))
    .join("")}`;
}

function parseHexColor(value: string): FloatingEffectRgb {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value.trim());
  if (!match) return { red: 31, green: 110, blue: 210 };
  return {
    red: Number.parseInt(match[1], 16),
    green: Number.parseInt(match[2], 16),
    blue: Number.parseInt(match[3], 16),
  };
}

function mixRgb(
  start: FloatingEffectRgb,
  end: FloatingEffectRgb,
  endWeight: number,
): FloatingEffectRgb {
  const startWeight = 1 - endWeight;
  return {
    red: start.red * startWeight + end.red * endWeight,
    green: start.green * startWeight + end.green * endWeight,
    blue: start.blue * startWeight + end.blue * endWeight,
  };
}

function clampColorChannel(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(255, Math.max(0, Math.round(value)));
}
