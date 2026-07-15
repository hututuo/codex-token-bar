import type {
  AutoResumeQuotaWindow,
  AutoResumeRuntimeStatus,
  AutoResumeScheduleMode,
  AutoResumeSettings,
} from "../types/dashboard";

export const AUTO_RESUME_INTERVAL_OPTIONS = [15, 30, 60, 120, 360, 720] as const;

export const DEFAULT_AUTO_RESUME_SETTINGS: AutoResumeSettings = {
  enabled: false,
  threadId: "",
  threadTitle: "",
  threadCwd: "",
  prompt: "继续",
  scheduleMode: "off",
  intervalMinutes: 60,
  dailyHour: 9,
  dailyMinute: 0,
  quotaResumeEnabled: true,
  quotaWindow: "either",
  quotaLowThresholdPercent: 5,
  quotaRecoveryThresholdPercent: 20,
  cooldownMinutes: 30,
  maxRunsPerDay: 6,
  notifyOnResult: true,
};

export const DEFAULT_AUTO_RESUME_STATUS: AutoResumeRuntimeStatus = {
  state: "disabled",
  message: "自动续跑未开启",
  isRunning: false,
  waitingForQuota: false,
  lastTrigger: null,
  lastRunAt: null,
  nextScheduledAt: null,
  runsToday: 0,
  revision: 0,
};

export function sanitizeAutoResumeSettings(
  settings?: Partial<AutoResumeSettings> | null,
): AutoResumeSettings {
  const source = settings ?? {};
  const threadId = cleanText(source.threadId, 128);
  const lowThreshold = clampWholeNumber(source.quotaLowThresholdPercent, 0, 20, 5);
  return {
    enabled: Boolean(source.enabled) && threadId.length > 0,
    threadId,
    threadTitle: cleanText(source.threadTitle, 240),
    threadCwd: cleanText(source.threadCwd, 2_048),
    prompt: cleanText(source.prompt, 8_000) || DEFAULT_AUTO_RESUME_SETTINGS.prompt,
    scheduleMode: sanitizeScheduleMode(source.scheduleMode),
    intervalMinutes: AUTO_RESUME_INTERVAL_OPTIONS.includes(source.intervalMinutes as typeof AUTO_RESUME_INTERVAL_OPTIONS[number])
      ? Number(source.intervalMinutes)
      : DEFAULT_AUTO_RESUME_SETTINGS.intervalMinutes,
    dailyHour: clampWholeNumber(source.dailyHour, 0, 23, DEFAULT_AUTO_RESUME_SETTINGS.dailyHour),
    dailyMinute: clampWholeNumber(source.dailyMinute, 0, 59, DEFAULT_AUTO_RESUME_SETTINGS.dailyMinute),
    quotaResumeEnabled: source.quotaResumeEnabled !== false,
    quotaWindow: sanitizeQuotaWindow(source.quotaWindow),
    quotaLowThresholdPercent: lowThreshold,
    quotaRecoveryThresholdPercent: clampWholeNumber(
      source.quotaRecoveryThresholdPercent,
      lowThreshold + 1,
      100,
      Math.max(DEFAULT_AUTO_RESUME_SETTINGS.quotaRecoveryThresholdPercent, lowThreshold + 1),
    ),
    cooldownMinutes: clampWholeNumber(source.cooldownMinutes, 1, 1_440, DEFAULT_AUTO_RESUME_SETTINGS.cooldownMinutes),
    maxRunsPerDay: clampWholeNumber(source.maxRunsPerDay, 1, 24, DEFAULT_AUTO_RESUME_SETTINGS.maxRunsPerDay),
    notifyOnResult: source.notifyOnResult !== false,
  };
}

export function formatAutoResumeTimestamp(value: number | null): string {
  if (value === null || !Number.isFinite(value) || value <= 0) return "尚无";
  const milliseconds = value < 10_000_000_000 ? value * 1_000 : value;
  const date = new Date(milliseconds);
  if (!Number.isFinite(date.getTime())) return "尚无";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

function sanitizeScheduleMode(value: unknown): AutoResumeScheduleMode {
  return value === "interval" || value === "daily" ? value : "off";
}

function sanitizeQuotaWindow(value: unknown): AutoResumeQuotaWindow {
  return value === "fiveHour" || value === "sevenDay" ? value : "either";
}

function cleanText(value: unknown, maxLength: number): string {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function clampWholeNumber(value: unknown, minimum: number, maximum: number, fallback: number): number {
  const number = typeof value === "number" ? value : Number.NaN;
  if (!Number.isFinite(number)) return fallback;
  return Math.min(maximum, Math.max(minimum, Math.round(number)));
}
