import type {
  AutoResumeFailureReason,
  AutoResumeQuotaWindow,
  AutoResumeRuntimeStatus,
  AutoResumeScheduleMode,
  AutoResumeSettings,
  AutoResumeTaskSettings,
} from "../types/dashboard";

export const AUTO_RESUME_INTERVAL_OPTIONS = [15, 30, 60, 120, 360, 720] as const;

export const AUTO_RESUME_FAILURE_REASONS: readonly {
  id: AutoResumeFailureReason;
  label: string;
  risky: boolean;
}[] = [
  { id: "capacity", label: "容量不足", risky: false },
  { id: "network", label: "网络断开", risky: false },
  { id: "rateLimit", label: "请求限流", risky: false },
  { id: "serverError", label: "服务端错误", risky: false },
  { id: "timeout", label: "请求超时", risky: false },
  { id: "retryLimit", label: "重试次数耗尽", risky: false },
  { id: "contextWindow", label: "上下文超限", risky: true },
  { id: "sessionBudget", label: "会话预算耗尽", risky: true },
  { id: "requestConflict", label: "请求状态冲突", risky: true },
  { id: "authentication", label: "登录或鉴权失败", risky: true },
  { id: "sandbox", label: "沙盒或权限错误", risky: true },
  { id: "interrupted", label: "任务被中断", risky: true },
  { id: "other", label: "其他失败", risky: true },
] as const;

export const DEFAULT_AUTO_RESUME_SETTINGS: AutoResumeSettings = {
  taskCollectionVersion: 2,
  selectedTaskId: "",
  tasks: [],
  enabled: false,
  threadId: "",
  threadTitle: "",
  threadCwd: "",
  prompt: "继续",
  scheduleMode: "off",
  intervalMinutes: 60,
  dailyHour: 9,
  dailyMinute: 0,
  failureRecoveryPolicyVersion: 1,
  failureRecoveryReasons: [],
  capacityRecoveryEnabled: false,
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
  taskId: null,
  runningTaskId: null,
  protectedTasks: 0,
  totalTasks: 0,
  tasks: [],
};

export function sanitizeAutoResumeSettings(
  settings?: Partial<AutoResumeSettings> | null,
): AutoResumeSettings {
  const source = settings ?? {};
  const legacy = sanitizeAutoResumeTaskSettings(source);
  const hasVersionedTaskCollection = Number(source.taskCollectionVersion) >= 2;
  const seenIds = new Set<string>();
  const seenThreads = new Set<string>();
  const providedTasks = Array.isArray(source.tasks) ? source.tasks : [];
  const tasks = providedTasks
    .map((task) => sanitizeAutoResumeTaskSettings(task))
    .filter((task) => {
      if (!task.threadId) return false;
      if (seenIds.has(task.id) || seenThreads.has(task.threadId)) return false;
      seenIds.add(task.id);
      seenThreads.add(task.threadId);
      return true;
    });
  if (!hasVersionedTaskCollection && tasks.length === 0 && legacy.threadId) {
    tasks.push({
      ...legacy,
      id: stableLegacyTaskId(legacy.threadId),
      createdAt: 0,
      updatedAt: 0,
    });
  }
  const requestedSelectedId = cleanText(source.selectedTaskId, 128);
  const selectedTaskId = tasks.some((task) => task.id === requestedSelectedId)
    ? requestedSelectedId
    : (tasks[0]?.id ?? "");
  const selected = tasks.find((task) => task.id === selectedTaskId);
  const rootConfiguration = selected
    ?? (hasVersionedTaskCollection ? sanitizeAutoResumeTaskSettings(null) : legacy);
  return {
    ...rootConfiguration,
    taskCollectionVersion: 2,
    selectedTaskId,
    tasks,
  };
}

export function sanitizeAutoResumeTaskSettings(
  settings?: Partial<AutoResumeTaskSettings> | Partial<AutoResumeSettings> | null,
): AutoResumeTaskSettings {
  const source = settings ?? {};
  const threadId = cleanText(source.threadId, 128);
  const lowThreshold = clampWholeNumber(source.quotaLowThresholdPercent, 0, 20, 5);
  const scheduleMode = sanitizeScheduleMode(source.scheduleMode);
  const hasFailurePolicy = Number(source.failureRecoveryPolicyVersion) >= 1;
  const requestedFailureReasons = hasFailurePolicy && Array.isArray(source.failureRecoveryReasons)
    ? source.failureRecoveryReasons
    : (source.capacityRecoveryEnabled === true ? ["capacity"] : []);
  const requestedFailureReasonSet = new Set(requestedFailureReasons);
  const failureRecoveryReasons = AUTO_RESUME_FAILURE_REASONS
    .map(({ id }) => id)
    .filter((reason) => requestedFailureReasonSet.has(reason));
  const capacityRecoveryEnabled = failureRecoveryReasons.length > 0;
  const quotaResumeEnabled = source.quotaResumeEnabled !== false;
  const hasTrigger = scheduleMode !== "off" || capacityRecoveryEnabled || quotaResumeEnabled;
  return {
    id: cleanText("id" in source ? source.id : "", 128) || stableLegacyTaskId(threadId),
    createdAt: clampTimestamp("createdAt" in source ? source.createdAt : 0),
    updatedAt: clampTimestamp("updatedAt" in source ? source.updatedAt : 0),
    enabled: Boolean(source.enabled) && threadId.length > 0 && hasTrigger,
    threadId,
    threadTitle: cleanText(source.threadTitle, 240),
    threadCwd: cleanText(source.threadCwd, 2_048),
    prompt: cleanText(source.prompt, 8_000) || DEFAULT_AUTO_RESUME_SETTINGS.prompt,
    scheduleMode,
    intervalMinutes: AUTO_RESUME_INTERVAL_OPTIONS.includes(source.intervalMinutes as typeof AUTO_RESUME_INTERVAL_OPTIONS[number])
      ? Number(source.intervalMinutes)
      : DEFAULT_AUTO_RESUME_SETTINGS.intervalMinutes,
    dailyHour: clampWholeNumber(source.dailyHour, 0, 23, DEFAULT_AUTO_RESUME_SETTINGS.dailyHour),
    dailyMinute: clampWholeNumber(source.dailyMinute, 0, 59, DEFAULT_AUTO_RESUME_SETTINGS.dailyMinute),
    failureRecoveryPolicyVersion: 1,
    failureRecoveryReasons,
    capacityRecoveryEnabled,
    quotaResumeEnabled,
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

export function createAutoResumeTask(
  thread: { id: string; title: string; cwd: string },
  now = Date.now(),
): AutoResumeTaskSettings {
  return sanitizeAutoResumeTaskSettings({
    ...DEFAULT_AUTO_RESUME_SETTINGS,
    id: globalThis.crypto?.randomUUID?.() ?? `task-${now}-${Math.random().toString(16).slice(2)}`,
    createdAt: now,
    updatedAt: now,
    enabled: false,
    threadId: thread.id,
    threadTitle: thread.title,
    threadCwd: thread.cwd,
  });
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

function clampTimestamp(value: unknown): number {
  const number = typeof value === "number" ? value : Number.NaN;
  return Number.isFinite(number) && number > 0 ? Math.round(number) : 0;
}

function stableLegacyTaskId(threadId: string): string {
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const mask = 0xffffffffffffffffn;
  for (const byte of new TextEncoder().encode(threadId)) {
    hash ^= BigInt(byte);
    hash = (hash * prime) & mask;
  }
  return `legacy-${hash.toString(16).padStart(16, "0")}`;
}
