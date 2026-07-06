import type { AccountQuotaBundle } from "../types/dashboard";

const NEAR_RESET_WINDOW_MS = 24 * 60 * 60 * 1_000;

export function compactQuotaLabel(limit: AccountQuotaBundle["quota"]["fiveHour"], now: Date = new Date()): string {
  const percent = Math.round(limit.remainingPercent * 100);
  return `${limit.label} ${percent}% ${compactQuotaResetText(limit, now)}`;
}

function compactQuotaResetText(limit: AccountQuotaBundle["quota"]["fiveHour"], now: Date): string {
  if (limit.label !== "7d" || typeof limit.resetsAtUnix !== "number" || !Number.isFinite(limit.resetsAtUnix)) {
    return limit.resetsAt;
  }

  const reset = new Date(limit.resetsAtUnix * 1_000);
  const remainingMs = reset.getTime() - now.getTime();
  if (remainingMs < 0 || remainingMs > NEAR_RESET_WINDOW_MS) {
    return limit.resetsAt;
  }

  const dayLabel = relativeLocalDayLabel(reset, now);
  if (!dayLabel) {
    return limit.resetsAt;
  }

  return `${dayLabel} ${formatLocalTime(reset)}`;
}

function relativeLocalDayLabel(date: Date, now: Date): "今天" | "明天" | null {
  const today = localDayStart(now);
  const targetDay = localDayStart(date);
  const dayDiff = Math.round((targetDay.getTime() - today.getTime()) / (24 * 60 * 60 * 1_000));

  if (dayDiff === 0) {
    return "今天";
  }
  if (dayDiff === 1) {
    return "明天";
  }
  return null;
}

function localDayStart(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function formatLocalTime(date: Date): string {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}
