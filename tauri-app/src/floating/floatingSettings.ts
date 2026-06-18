export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
}

export const FLOATING_SETTINGS_EVENT = "floating-settings-changed";
export const FLOATING_BASE_WIDTH = 296;
export const FLOATING_BASE_HEIGHT = 98;

const FLOATING_SETTINGS_KEY = "codex-token-bar-floating-settings-v1";

export const DEFAULT_FLOATING_SETTINGS: FloatingWindowSettings = {
  opacity: 0.92,
  scale: 1,
};

export function readFloatingSettings(): FloatingWindowSettings {
  try {
    const raw = window.localStorage.getItem(FLOATING_SETTINGS_KEY);
    if (raw === null) {
      return DEFAULT_FLOATING_SETTINGS;
    }

    return sanitizeFloatingSettings(JSON.parse(raw) as Partial<FloatingWindowSettings>);
  } catch {
    return DEFAULT_FLOATING_SETTINGS;
  }
}

export function writeFloatingSettings(settings: FloatingWindowSettings) {
  window.localStorage.setItem(FLOATING_SETTINGS_KEY, JSON.stringify(sanitizeFloatingSettings(settings)));
}

export function sanitizeFloatingSettings(
  settings: Partial<FloatingWindowSettings>,
): FloatingWindowSettings {
  return {
    opacity: clampNumber(settings.opacity, 0.4, 1, DEFAULT_FLOATING_SETTINGS.opacity),
    scale: clampNumber(settings.scale, 0.9, 1.38, DEFAULT_FLOATING_SETTINGS.scale),
  };
}

function clampNumber(value: unknown, minimum: number, maximum: number, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.min(maximum, Math.max(minimum, value));
}
