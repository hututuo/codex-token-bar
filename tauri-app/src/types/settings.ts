export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
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
export type FloatingGradientType = "linear" | "radial";
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
