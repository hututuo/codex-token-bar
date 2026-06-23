export type { FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";
import type { FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";

export const FLOATING_SETTINGS_EVENT = "floating-settings-changed";
export const FLOATING_BASE_WIDTH = 296;
export const FLOATING_BASE_HEIGHT = 112;

export const DEFAULT_FLOATING_SETTINGS: FloatingWindowSettings = {
  opacity: 0.92,
  scale: 1,
  unreadEffect: "ripple",
  gradientStart: "#ffffff",
  gradientEnd: "#daefff",
  gradientDirection: "135deg",
  gradientType: "linear",
};

export function sanitizeFloatingSettings(
  settings: Partial<FloatingWindowSettings>,
): FloatingWindowSettings {
  return {
    opacity: clampNumber(settings.opacity, 0.4, 1, DEFAULT_FLOATING_SETTINGS.opacity),
    scale: clampNumber(settings.scale, 0.9, 1.38, DEFAULT_FLOATING_SETTINGS.scale),
    unreadEffect: sanitizeUnreadEffect(settings.unreadEffect),
    gradientStart: sanitizeHexColor(settings.gradientStart, DEFAULT_FLOATING_SETTINGS.gradientStart),
    gradientEnd: sanitizeHexColor(settings.gradientEnd, DEFAULT_FLOATING_SETTINGS.gradientEnd),
    gradientDirection: sanitizeGradientDirection(settings.gradientDirection),
    gradientType: sanitizeGradientType(settings.gradientType),
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

function sanitizeHexColor(value: unknown, fallback: string): string {
  if (typeof value !== "string") {
    return fallback;
  }
  const trimmed = value.trim();
  return /^#[0-9a-fA-F]{6}$/.test(trimmed) ? trimmed.toLowerCase() : fallback;
}

function sanitizeGradientDirection(value: unknown): FloatingWindowSettings["gradientDirection"] {
  if (value === "135deg" || value === "90deg" || value === "180deg" || value === "45deg") {
    return value;
  }
  return DEFAULT_FLOATING_SETTINGS.gradientDirection;
}

function sanitizeGradientType(value: unknown): FloatingWindowSettings["gradientType"] {
  if (value === "linear" || value === "radial") {
    return value;
  }
  return DEFAULT_FLOATING_SETTINGS.gradientType;
}
