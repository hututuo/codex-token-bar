export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
  unreadEffect: FloatingUnreadEffect;
  gradientStart: string;
  gradientEnd: string;
  gradientDirection: FloatingGradientDirection;
  gradientType: FloatingGradientType;
}

export type FloatingUnreadEffect = "off" | "ripple" | "shimmer";
export type FloatingGradientDirection = "135deg" | "90deg" | "180deg" | "45deg";
export type FloatingGradientType = "linear" | "radial";

export interface AppSettingsSnapshot {
  codexHome: string | null;
  floatingWindow: FloatingWindowSettings;
  floatingPosition: FloatingWindowPosition | null;
  displaySurfaces: DisplaySurfaceSettings;
  setupGuideCompleted: boolean;
}

export interface FloatingWindowPosition {
  x: number;
  y: number;
  savedAt?: number | null;
}

export interface DisplaySurfaceSettings {
  floatingWindowEnabled: boolean;
  statusTrayLiveTextEnabled: boolean;
}
