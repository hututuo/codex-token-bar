import type { ResetCreditDetail, ResetCreditSummary } from "../../types/dashboard";

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

export type ResetCreditExpiryState = "future" | "unknown" | "past";

export interface ResetCreditDisplayItem {
  credit: ResetCreditDetail;
  compactRemainingText: string;
  detailedRemainingText: string;
  expiryState: ResetCreditExpiryState;
  hasFutureExpiry: boolean;
  isCountdownEligible: boolean;
  isCountedAvailable: boolean;
  remainingProgress: number;
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
    .map((credit) => {
      const isCountedAvailable = isCountedAvailableResetCredit(credit);
      const expiryState = resetCreditExpiryState(credit, now);
      const hasFutureExpiry = expiryState === "future";
      return {
        credit,
        compactRemainingText: compactRemainingTimeText(credit, now),
        detailedRemainingText: detailedRemainingTimeText(credit, now),
        expiryState,
        hasFutureExpiry,
        isCountdownEligible: isCountedAvailable && hasFutureExpiry,
        isCountedAvailable,
        remainingProgress: remainingProgress(credit, now),
      };
    });
}

export function nearestResetCreditCompactText(
  summary: ResetCreditSummary,
  now: Date = new Date(),
): string | null {
  const nearest = prepareResetCreditsForDisplay(summary.credits ?? [], now)
    .find((item) => item.isCountdownEligible);
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
  if (total === 0 && available > 0) {
    return `共 0 张；可用 ${available} 张 · 单卡明细暂不可用`;
  }
  const hasFutureExpiry = displayItems.some((item) => item.isCountdownEligible);
  const sortDescription = hasFutureExpiry ? "按最近到期排序" : "按状态和到期信息排序";
  return `共 ${total} 张；可用 ${available} 张 · ${sortDescription}`;
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
    emptyText: resetCreditEmptyText(summary, available),
    nearestText: nearestResetCreditCompactText(summary, now),
    subtitle: resetCreditPanelSubtitle(summary, displayItems, now),
  };
}

export function resetCreditDetailKey(credit: ResetCreditDetail, index: number): string {
  return `${cardIdentifier(credit)}-${index}`;
}

export function resetCreditEmptyText(summary: ResetCreditSummary, availableCount?: number): string {
  const available = availableCount ?? availableResetCreditCount(summary);
  if ((summary.credits?.length ?? 0) === 0 && available > 0) {
    return `已读到 ${available} 张可用重置卡，但暂时没有单卡明细。`;
  }
  return `没有读到单张重置卡明细；当前接口状态：${summary.status}`;
}

export function displaySortPrecedes(
  left: ResetCreditDetail,
  right: ResetCreditDetail,
  now: Date = new Date(),
): boolean {
  const leftGroup = displaySortGroup(left, now);
  const rightGroup = displaySortGroup(right, now);
  if (leftGroup !== rightGroup) {
    return leftGroup < rightGroup;
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

function displaySortGroup(credit: ResetCreditDetail, now: Date): number {
  if (isCountedAvailableResetCredit(credit)) {
    switch (resetCreditExpiryState(credit, now)) {
      case "future":
        return 0;
      case "unknown":
        return 1;
      case "past":
        return 2;
    }
  }
  if (credit.status === "已过期") {
    return 3;
  }
  return 4;
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

function resetCreditExpiryState(credit: ResetCreditDetail, now: Date): ResetCreditExpiryState {
  const expiresAt = timestampMillis(credit.expiresAtUnix);
  if (expiresAt === null) {
    return "unknown";
  }
  return expiresAt > now.getTime() ? "future" : "past";
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
  if (!isCountedAvailableResetCredit(credit)) {
    return 0;
  }
  return resetCreditExpiryState(credit, now) === "past" ? 0 : 1;
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
