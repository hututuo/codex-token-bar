export interface FloatingWindowSettings {
  opacity: number;
  scale: number;
  tokenRateFullScale: number;
  unreadEffect: FloatingUnreadEffect;
  gradientStart: string;
  gradientEnd: string;
  gradientDirection: FloatingGradientDirection;
  gradientType: FloatingGradientType;
  quotaColorMode: FloatingQuotaColorMode;
  quotaFixedColor: string;
  textTone: number;
  contentVisibility: FloatingContentVisibility;
}

export type FloatingUnreadEffect = "off" | "ripple" | "shimmer";
export type FloatingGradientDirection = "135deg" | "90deg" | "180deg" | "45deg";
export type FloatingGradientType = "linear" | "radial" | "conic";
export type FloatingQuotaColorMode = "adaptive" | "fixed" | "panelGradient";
export type FloatingPalettePatch = Partial<Pick<
  FloatingWindowSettings,
  "gradientStart" | "gradientEnd" | "gradientDirection" | "gradientType" | "quotaColorMode" | "quotaFixedColor"
>>;
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
  quotaRefreshIntervalMs: number;
  floatingWindow: FloatingWindowSettings;
  floatingPosition: FloatingWindowPosition | null;
  displaySurfaces: DisplaySurfaceSettings;
  setupGuideCompleted: boolean;
  autoResume: AutoResumeSettings;
}

export type AutoResumeScheduleMode = "off" | "interval" | "daily";
export type AutoResumeQuotaWindow = "fiveHour" | "sevenDay" | "either";

export interface AutoResumeSettings {
  enabled: boolean;
  threadId: string;
  threadTitle: string;
  threadCwd: string;
  prompt: string;
  scheduleMode: AutoResumeScheduleMode;
  intervalMinutes: number;
  dailyHour: number;
  dailyMinute: number;
  quotaResumeEnabled: boolean;
  quotaWindow: AutoResumeQuotaWindow;
  quotaLowThresholdPercent: number;
  quotaRecoveryThresholdPercent: number;
  cooldownMinutes: number;
  maxRunsPerDay: number;
  notifyOnResult: boolean;
}

export interface AutoResumeThreadOption {
  id: string;
  title: string;
  cwd: string;
  updatedAt: number;
  status: string;
  source: string;
}

export interface AutoResumeRuntimeStatus {
  state: string;
  message: string;
  isRunning: boolean;
  waitingForQuota: boolean;
  lastTrigger: string | null;
  lastRunAt: number | null;
  nextScheduledAt: number | null;
  runsToday: number;
  revision: number;
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
