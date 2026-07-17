export type { FloatingUnreadEffect, FloatingWindowSettings } from "../types/dashboard";
import type {
  FloatingContentGroup,
  FloatingContentVisibility,
  FloatingUnreadEffect,
  FloatingWindowSettings,
} from "../types/dashboard";

export const FLOATING_SETTINGS_EVENT = "floating-settings-changed";
export const FLOATING_BASE_WIDTH = 296;
export const FLOATING_MIN_HEIGHT = 88;
export const FLOATING_DEFAULT_HEIGHT = 134;

const FLOATING_CONTENT_GROUPS: FloatingContentGroup[] = [
  "rateAndBar",
  "usageStatus",
  "metrics",
  "radar",
  "crowdRadar",
  "quota",
];

const DEFAULT_FLOATING_CONTENT_VISIBILITY: FloatingContentVisibility = {
  showRateAndBar: true,
  showUsageStatus: true,
  showMetrics: true,
  showQuota: true,
  showRadar: true,
  showCrowdRadar: true,
  order: FLOATING_CONTENT_GROUPS,
};

export const DEFAULT_FLOATING_SETTINGS: FloatingWindowSettings = {
  opacity: 0.92,
  scale: 1,
  tokenRateFullScale: 200,
  unreadEffect: "ripple",
  gradientStart: "#ffffff",
  gradientEnd: "#daefff",
  gradientDirection: "135deg",
  gradientType: "linear",
  quotaColorMode: "adaptive",
  quotaFixedColor: "#1469cc",
  textTone: -1,
  contentVisibility: DEFAULT_FLOATING_CONTENT_VISIBILITY,
};

export function sanitizeFloatingSettings(
  settings: Partial<FloatingWindowSettings>,
): FloatingWindowSettings {
  return {
    opacity: clampNumber(settings.opacity, 0.4, 1, DEFAULT_FLOATING_SETTINGS.opacity),
    scale: clampNumber(settings.scale, 0.9, 1.38, DEFAULT_FLOATING_SETTINGS.scale),
    tokenRateFullScale: clampNumber(settings.tokenRateFullScale, 50, 400, DEFAULT_FLOATING_SETTINGS.tokenRateFullScale),
    unreadEffect: sanitizeUnreadEffect(settings.unreadEffect),
    gradientStart: sanitizeHexColor(settings.gradientStart, DEFAULT_FLOATING_SETTINGS.gradientStart),
    gradientEnd: sanitizeHexColor(settings.gradientEnd, DEFAULT_FLOATING_SETTINGS.gradientEnd),
    gradientDirection: sanitizeGradientDirection(settings.gradientDirection),
    gradientType: sanitizeGradientType(settings.gradientType),
    quotaColorMode: sanitizeQuotaColorMode(settings.quotaColorMode),
    quotaFixedColor: sanitizeHexColor(settings.quotaFixedColor, DEFAULT_FLOATING_SETTINGS.quotaFixedColor),
    textTone: clampNumber(settings.textTone, -1, 1, DEFAULT_FLOATING_SETTINGS.textTone),
    contentVisibility: sanitizeFloatingContentVisibility(settings.contentVisibility),
  };
}

export function floatingGradientBackground(
  settings: Pick<FloatingWindowSettings, "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType">,
): string {
  if (settings.gradientType === "radial") {
    return `radial-gradient(circle at 18% 10%, ${settings.gradientStart}, ${settings.gradientEnd})`;
  }
  if (settings.gradientType === "conic") {
    return `conic-gradient(from ${settings.gradientDirection} at 50% 50%, ${settings.gradientStart}, ${settings.gradientEnd}, ${settings.gradientStart})`;
  }
  return `linear-gradient(${settings.gradientDirection}, ${settings.gradientStart}, ${settings.gradientEnd})`;
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
  if (value === "linear" || value === "radial" || value === "conic") {
    return value;
  }
  return DEFAULT_FLOATING_SETTINGS.gradientType;
}

function sanitizeQuotaColorMode(value: unknown): FloatingWindowSettings["quotaColorMode"] {
  if (value === "adaptive" || value === "fixed" || value === "panelGradient") {
    return value;
  }
  return DEFAULT_FLOATING_SETTINGS.quotaColorMode;
}

function sanitizeFloatingContentVisibility(value: Partial<FloatingContentVisibility> | undefined): FloatingContentVisibility {
  return {
    showRateAndBar: value?.showRateAndBar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRateAndBar,
    showUsageStatus: value?.showUsageStatus ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showUsageStatus,
    showMetrics: value?.showMetrics ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showMetrics,
    showQuota: value?.showQuota ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showQuota,
      showRadar: value?.showRadar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRadar,
      showCrowdRadar: value?.showCrowdRadar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showCrowdRadar,
    order: sanitizeContentOrder(value?.order),
  };
}

function sanitizeContentOrder(value: unknown): FloatingContentGroup[] {
  const input = Array.isArray(value) ? value : [];
  const seen = new Set<FloatingContentGroup>();
  const decoded = input.filter((item): item is FloatingContentGroup => {
    if (!FLOATING_CONTENT_GROUPS.includes(item as FloatingContentGroup) || seen.has(item as FloatingContentGroup)) {
      return false;
    }
    seen.add(item as FloatingContentGroup);
    return true;
  });
  return [...decoded, ...FLOATING_CONTENT_GROUPS.filter((group) => !seen.has(group))];
}
