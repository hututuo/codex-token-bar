import type { ResetCreditDetail, ResetCreditSummary } from "../../types/dashboard";

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

export interface ResetCreditDisplayItem {
  credit: ResetCreditDetail;
  compactRemainingText: string;
  detailedRemainingText: string;
  remainingProgress: number;
  isAvailable: boolean;
}

export interface ResetCreditPanelModel {
  availableText: string;
  countText: string;
  displayItems: ResetCreditDisplayItem[];
  emptyText: string;
  nearestText: string | null;
  subtitle: string;
}

export function prepareResetCreditsForDisplay(
  credits: ResetCreditDetail[],
  now: Date = new Date(),
): ResetCreditDisplayItem[] {
  return [...credits]
    .sort((left, right) => {
      if (displaySortPrecedes(left, right, now)) {
        return -1;
      }
      if (displaySortPrecedes(right, left, now)) {
        return 1;
      }
      return 0;
    })
    .map((credit) => ({
      credit,
      compactRemainingText: compactRemainingTimeText(credit, now),
      detailedRemainingText: detailedRemainingTimeText(credit, now),
      remainingProgress: remainingProgress(credit, now),
      isAvailable: isAvailableResetCredit(credit, now),
    }));
}

export function nearestResetCreditCompactText(
  summary: ResetCreditSummary,
  now: Date = new Date(),
): string | null {
  const nearest = prepareResetCreditsForDisplay(summary.credits ?? [], now)
    .find((item) => item.isAvailable && hasFutureResetCreditExpiry(item.credit, now));
  return nearest ? `最近 ${nearest.compactRemainingText}` : null;
}

export function resetCreditCountText(summary: ResetCreditSummary, now: Date = new Date()): string {
  const count = availableResetCreditCount(summary, now);
  if (count > 0 || (summary.credits?.length ?? 0) > 0) {
    return `${count} 张重置卡`;
  }
  return summary.status || "重置卡";
}

export function resetCreditPanelSubtitle(
  summary: ResetCreditSummary,
  displayItems: ResetCreditDisplayItem[],
  now: Date = new Date(),
): string {
  const total = displayItems.length;
  const available = availableResetCreditCount(summary, now);
  return `共 ${total} 张；可用 ${available} 张 · 按最近到期排序`;
}

export function availableResetCreditCount(
  summary: ResetCreditSummary,
  now: Date = new Date(),
): number {
  const reported = Math.max(0, Math.trunc(summary.availableCount ?? 0));
  const fromDetails = (summary.credits ?? []).filter(isCountedAvailableResetCredit).length;
  return Math.max(reported, fromDetails);
}

export function resetCreditPanelModel(
  summary: ResetCreditSummary,
  now: Date = new Date(),
): ResetCreditPanelModel {
  const displayItems = prepareResetCreditsForDisplay(summary.credits ?? [], now);
  const available = availableResetCreditCount(summary, now);
  return {
    availableText: `${available} 张可用`,
    countText: resetCreditCountText(summary, now),
    displayItems,
    emptyText: resetCreditEmptyText(summary),
    nearestText: nearestResetCreditCompactText(summary, now),
    subtitle: resetCreditPanelSubtitle(summary, displayItems, now),
  };
}

export function resetCreditDetailKey(credit: ResetCreditDetail, index: number): string {
  return `${cardIdentifier(credit)}-${index}`;
}

export function resetCreditEmptyText(summary: ResetCreditSummary): string {
  return `没有读到单张重置卡明细；当前接口状态：${summary.status}`;
}

export function displaySortPrecedes(
  left: ResetCreditDetail,
  right: ResetCreditDetail,
  now: Date = new Date(),
): boolean {
  const leftAvailable = isAvailableResetCredit(left, now);
  const rightAvailable = isAvailableResetCredit(right, now);
  if (leftAvailable !== rightAvailable) {
    return leftAvailable;
  }

  const leftExpiry = timestampMillis(left.expiresAtUnix);
  const rightExpiry = timestampMillis(right.expiresAtUnix);
  if (leftExpiry !== null && rightExpiry !== null && leftExpiry !== rightExpiry) {
    return leftExpiry < rightExpiry;
  }
  if (leftExpiry !== null && rightExpiry === null) {
    return true;
  }
  if (leftExpiry === null && rightExpiry !== null) {
    return false;
  }

  return cardIdentifier(left).localeCompare(cardIdentifier(right), "zh-Hans-CN", {
    numeric: true,
    sensitivity: "base",
  }) < 0;
}

export function isAvailableResetCredit(credit: ResetCreditDetail, now: Date = new Date()): boolean {
  if (!isCountedAvailableResetCredit(credit)) {
    return false;
  }
  const expiresAt = timestampMillis(credit.expiresAtUnix);
  return expiresAt === null || expiresAt > now.getTime();
}

function isCountedAvailableResetCredit(credit: ResetCreditDetail): boolean {
  if (credit.status !== "可用") {
    return false;
  }
  if (credit.redeemedAt && credit.redeemedAt !== "未使用" && credit.redeemedAt !== "未提供") {
    return false;
  }
  return true;
}

function hasFutureResetCreditExpiry(credit: ResetCreditDetail, now: Date): boolean {
  const expiresAt = timestampMillis(credit.expiresAtUnix);
  return expiresAt !== null && expiresAt > now.getTime();
}

export function compactRemainingTimeText(
  credit: ResetCreditDetail,
  now: Date = new Date(),
): string {
  const expiresAt = timestampMillis(credit.expiresAtUnix);
  if (expiresAt === null) {
    return "到期未知";
  }
  const remaining = expiresAt - now.getTime();
  if (remaining <= 0) {
    return "已到期";
  }
  if (remaining < HOUR_MS) {
    return "剩 <1h";
  }
  const days = Math.floor(remaining / DAY_MS);
  const hours = Math.floor((remaining % DAY_MS) / HOUR_MS);
  if (days > 0) {
    return `剩 ${days}天${hours}h`;
  }
  const minutes = Math.floor((remaining % HOUR_MS) / MINUTE_MS);
  return `剩 ${hours}h${minutes}m`;
}

export function detailedRemainingTimeText(
  credit: ResetCreditDetail,
  now: Date = new Date(),
): string {
  const expiresAt = timestampMillis(credit.expiresAtUnix);
  if (expiresAt === null) {
    return "到期时间未知";
  }
  const remaining = expiresAt - now.getTime();
  if (remaining <= 0) {
    return "已经到期";
  }
  if (remaining < HOUR_MS) {
    return "不到 1 小时后到期";
  }
  const days = Math.floor(remaining / DAY_MS);
  const hours = Math.floor((remaining % DAY_MS) / HOUR_MS);
  if (days > 0) {
    return `约 ${days} 天 ${hours} 小时后到期`;
  }
  return `约 ${hours} 小时后到期`;
}

export function remainingProgress(
  credit: ResetCreditDetail,
  now: Date = new Date(),
): number {
  const grantedAt = timestampMillis(credit.grantedAtUnix);
  const expiresAt = timestampMillis(credit.expiresAtUnix);
  if (grantedAt !== null && expiresAt !== null && expiresAt > grantedAt) {
    return clamp01((expiresAt - now.getTime()) / (expiresAt - grantedAt));
  }
  return isAvailableResetCredit(credit, now) ? 1 : 0;
}

export function cardIdentifier(credit: ResetCreditDetail): string {
  return credit.cardId || credit.shortId || "未提供";
}

function timestampMillis(value: number | null | undefined): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  return value > 10_000_000_000 ? value : value * 1000;
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(1, Math.max(0, value));
}
