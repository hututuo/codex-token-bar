import type { FloatingContentGroup, FloatingWindowSettings } from "../types/dashboard";

export interface FloatingTextPalette {
  primary: string;
  secondary: string;
  muted: string;
  divider: string;
}

interface Rgb {
  r: number;
  g: number;
  b: number;
}

export function floatingTextPaletteForGroup(
  settings: FloatingWindowSettings,
  _group: FloatingContentGroup,
  _index: number,
  _total: number,
): FloatingTextPalette {
  if (settings.textTone >= 0) {
    return fixedPalette(settings.textTone);
  }

  const strength = Math.abs(settings.textTone);
  const averaged = averageGradientRgb(settings.gradientStart, settings.gradientEnd);
  const useLight = luminance(averaged) <= 0.46;

  if (useLight) {
    return {
      primary: `rgba(255, 255, 255, ${mix(0.86, 0.96, strength).toFixed(3)})`,
      secondary: `rgba(238, 244, 255, ${mix(0.78, 0.92, strength).toFixed(3)})`,
      muted: `rgba(226, 235, 248, ${mix(0.66, 0.82, strength).toFixed(3)})`,
      divider: `rgba(235, 242, 255, ${mix(0.20, 0.34, strength).toFixed(3)})`,
    };
  }

  return {
    primary: `rgba(18, 24, 34, ${mix(0.94, 0.99, strength).toFixed(3)})`,
    secondary: `rgba(38, 48, 62, ${mix(0.82, 0.94, strength).toFixed(3)})`,
    muted: `rgba(58, 70, 88, ${mix(0.70, 0.84, strength).toFixed(3)})`,
    divider: `rgba(37, 47, 62, ${mix(0.20, 0.34, strength).toFixed(3)})`,
  };
}

function fixedPalette(white: number): FloatingTextPalette {
  const clamped = clamp(white, 0, 1);
  const value = Math.round(clamped * 255);
  return {
    primary: `rgba(${value}, ${value}, ${value}, 0.96)`,
    secondary: `rgba(${value}, ${value}, ${value}, 0.84)`,
    muted: `rgba(${value}, ${value}, ${value}, 0.68)`,
    divider: `rgba(${value}, ${value}, ${value}, 0.28)`,
  };
}

function parseHex(value: string): Rgb {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value.trim());
  if (!match) {
    return { r: 218, g: 239, b: 255 };
  }
  return {
    r: Number.parseInt(match[1], 16),
    g: Number.parseInt(match[2], 16),
    b: Number.parseInt(match[3], 16),
  };
}

function averageGradientRgb(startHex: string, endHex: string): Rgb {
  const start = parseHex(startHex);
  const end = parseHex(endHex);
  return {
    r: Math.round((start.r + end.r) / 2),
    g: Math.round((start.g + end.g) / 2),
    b: Math.round((start.b + end.b) / 2),
  };
}

function luminance(color: Rgb): number {
  return (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b) / 255;
}

function mix(from: number, to: number, progress: number): number {
  return from + (to - from) * clamp(progress, 0, 1);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
