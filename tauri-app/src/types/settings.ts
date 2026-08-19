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
  pagingGuideRevision: number;
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
export type FloatingContentGroup =
  | "rateAndBar"
  | "usageStatus"
  | "metrics"
  | "runningThreads"
  | "todayModelShare"
  | "todayModelCost"
  | "quota"
  | "radar"
  | "crowdRadar";

export interface FloatingContentVisibility {
  showRateAndBar: boolean;
  showUsageStatus: boolean;
  showMetrics: boolean;
  showRunningThreads: boolean;
  showTodayModelShare: boolean;
  showTodayModelCost: boolean;
  showQuota: boolean;
  showRadar: boolean;
  showCrowdRadar: boolean;
  crowdRadarPageCount: number;
  showPageNavigationArrows: boolean;
  order: FloatingContentGroup[];
  pagePairs: FloatingContentPagePair[];
}

export type FloatingContentPagePair = [FloatingContentGroup, FloatingContentGroup];

export interface AppSettingsSnapshot {
  codexHome: string | null;
  customAccountDisplayName: string;
  quotaRefreshIntervalMs: number;
  usageLightRefreshIntervalSeconds: number;
  usageVisibleAggregateIntervalMinutes: number;
  usageBackgroundAggregateIntervalMinutes: number;
  floatingWindow: FloatingWindowSettings;
  floatingPosition: FloatingWindowPosition | null;
  displaySurfaces: DisplaySurfaceSettings;
  setupGuideCompleted: boolean;
  sessionEnhancements: SessionEnhancementSettings;
  autoResume: AutoResumeSettings;
}

export interface UsageRefreshSettings {
  usageLightRefreshIntervalSeconds: number;
  usageVisibleAggregateIntervalMinutes: number;
  usageBackgroundAggregateIntervalMinutes: number;
}

export type UsageRefreshCadenceSettings = UsageRefreshSettings;

export interface SessionEnhancementSettings {
  sessionDelete: boolean;
  markdownExport: boolean;
  pasteFix: boolean;
  projectMove: boolean;
  threadIDBadge: boolean;
  conversationView: boolean;
  conversationViewMaxWidth: number;
  threadScrollRestore: boolean;
}

export type AutoResumeScheduleMode = "off" | "interval" | "daily";
export type AutoResumeQuotaWindow = "fiveHour" | "sevenDay" | "either";
export type AutoResumeFailureReason =
  | "serverOverloaded"
  | "httpConnectionFailed"
  | "responseStreamConnectionFailed"
  | "responseStreamDisconnected"
  | "responseTooManyFailedAttempts"
  | "internalServerError"
  | "interrupted"
  | "contextWindowExceeded"
  | "sessionBudgetExceeded"
  | "unauthorized"
  | "badRequest"
  | "sandboxError"
  | "cyberPolicy"
  | "other";

export interface AutoResumeTaskConfiguration {
  enabled: boolean;
  threadId: string;
  threadTitle: string;
  threadCwd: string;
  prompt: string;
  invisibleResumeEnabled: boolean;
  autoApprovalEnabled: boolean;
  scheduleMode: AutoResumeScheduleMode;
  intervalMinutes: number;
  dailyHour: number;
  dailyMinute: number;
  failureRecoveryPolicyVersion: number;
  failureRecoveryReasons: AutoResumeFailureReason[];
  capacityRecoveryEnabled: boolean;
  quotaResumeEnabled: boolean;
  quotaWindow: AutoResumeQuotaWindow;
  quotaLowThresholdPercent: number;
  quotaRecoveryThresholdPercent: number;
  cooldownMinutes: number;
  maxRunsPerDay: number;
  notifyOnResult: boolean;
}

export interface AutoResumeTaskSettings extends AutoResumeTaskConfiguration {
  id: string;
  createdAt: number;
  updatedAt: number;
}

export interface AutoResumeSettings extends AutoResumeTaskConfiguration {
  taskCollectionVersion: number;
  selectedTaskId: string;
  tasks: AutoResumeTaskSettings[];
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
  taskId: string | null;
  runningTaskId: string | null;
  protectedTasks: number;
  totalTasks: number;
  tasks: AutoResumeTaskRuntimeStatus[];
}

export interface AutoResumeTaskRuntimeStatus {
  taskId: string;
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

export type StatusMetricId =
  | "rate"
  | "fiveHour"
  | "sevenDay"
  | "iq"
  | "today"
  | "total"
  | "requests"
  | "running"
  | "unread";

export type StatusMetricLabelStyle = "full" | "compact" | "hidden";

export type StatusSummarySectionId =
  | "overview"
  | "usage"
  | "quota"
  | "running"
  | "unread"
  | "radar"
  | "crowdRadar";

export interface DisplaySurfaceSettings {
  floatingWindowEnabled: boolean;
  liveRateEnabled: boolean;
  statusTrayLiveTextEnabled: boolean;
  statusMetricOrder: StatusMetricId[];
  statusMetricLabelStyle: StatusMetricLabelStyle;
  statusSummaryOrder: StatusSummarySectionId[];
}
