export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
  tokenRateFullScale: number;
  unreadEffect: FloatingUnreadEffect;
  gradientStart: string;
  gradientEnd: string;
  gradientDirection: FloatingGradientDirection;
  gradientType: FloatingGradientType;
  textTone: number;
  contentVisibility: FloatingContentVisibility;
}

export type FloatingUnreadEffect = "off" | "ripple" | "shimmer";
export type FloatingGradientDirection = "135deg" | "90deg" | "180deg" | "45deg";
export type FloatingGradientType = "linear" | "radial" | "conic";
export type FloatingContentGroup = "rateAndBar" | "usageStatus" | "metrics" | "quota" | "radar";

export interface FloatingContentVisibility {
  showRateAndBar: boolean;
  showUsageStatus: boolean;
  showMetrics: boolean;
  showQuota: boolean;
  showRadar: boolean;
  order: FloatingContentGroup[];
}

export interface AppSettingsSnapshot {
  codexHome: string | null;
  customAccountDisplayName: string;
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
  liveRateEnabled: boolean;
  statusTrayLiveTextEnabled: boolean;
}
