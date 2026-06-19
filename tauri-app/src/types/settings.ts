export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
  unreadEffect: FloatingUnreadEffect;
}

export type FloatingUnreadEffect = "off" | "ripple" | "shimmer";

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
