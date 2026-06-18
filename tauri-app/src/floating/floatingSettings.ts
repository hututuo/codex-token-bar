export type { FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";
import type { FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";

export const FLOATING_SETTINGS_EVENT = "floating-settings-changed";
export const FLOATING_BASE_WIDTH = 296;
export const FLOATING_BASE_HEIGHT = 112;

export const DEFAULT_FLOATING_SETTINGS: FloatingWindowSettings = {
  opacity: 0.92,
  scale: 1,
  unreadEffect: "ripple",
};

export function sanitizeFloatingSettings(
  settings: Partial<FloatingWindowSettings>,
): FloatingWindowSettings {
  return {
    opacity: clampNumber(settings.opacity, 0.4, 1, DEFAULT_FLOATING_SETTINGS.opacity),
    scale: clampNumber(settings.scale, 0.9, 1.38, DEFAULT_FLOATING_SETTINGS.scale),
    unreadEffect: sanitizeUnreadEffect(settings.unreadEffect),
  };
}

export function sanitizeUnreadEffect(value: unknown): FloatingUnreadEffect {
  if (value === "off" || value === "ripple" || value === "shimmer") {
    return value;
  }
  return DEFAULT_FLOATING_SETTINGS.unreadEffect;
}

function clampNumber(value: unknown, minimum: number, maximum: number, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.min(maximum, Math.max(minimum, value));
}
