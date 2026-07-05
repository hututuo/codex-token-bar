import type { ResetCreditDetail, ResetCreditSummary } from "../types/dashboard";

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

export function compactFloatingPaceLabel(label: string): string {
  const normalized = label.trim();
  if (!normalized || normalized === "额度待读取") {
    return normalized;
  }
  const delta = compactQuotaDelta(normalized);
  if (normalized.includes("不够烧") || normalized.includes("用得太快") || normalized.includes("先省着")) {
    return withDetail("先省着", delta || compactRemainingDetail(normalized));
  }
  if (normalized.includes("刹一脚")) {
    return withDetail("刹一脚", delta);
  }
  if (normalized.includes("用得偏快") || normalized.includes("慢一点")) {
    return withDetail("慢一点", delta);
  }
  if (normalized.includes("略快")) {
    return withDetail("略快", delta);
  }
  if (normalized.includes("余量很足") || normalized.includes("余量很富") || normalized.includes("使劲蹬")) {
    return withDetail("余量足", delta);
  }
  if (normalized.includes("节奏很好") || normalized.includes("节奏稳") || normalized.includes("可以冲")) {
    return stableWithDetail(delta);
  }
  if (normalized.includes("略有余量") || normalized.includes("正好贴着") || normalized.includes("贴近均速")) {
    return stableWithDetail(delta || compactInlineDelta(normalized));
  }
  return normalized.replace(/（[^）]*）/g, "").trim();
}

function compactQuotaDelta(label: string): string {
  const match = /(?:（|\()\s*(?:余量)?(高|多|低)\s*([0-9]+(?:\.[0-9]+)?)\s*%\s*(?:）|\))/.exec(label)
    ?? /(?:余量)?(高|多|低)\s*([0-9]+(?:\.[0-9]+)?)\s*%/.exec(label);
  if (!match) {
    return "";
  }
  const direction = match[1] === "多" ? "高" : match[1];
  return `余量${direction}${match[2]}%`;
}

function compactRemainingDetail(label: string): string {
  const match = /([0-9]+(?:\.[0-9]+)?)\s*%\s*剩/.exec(label)
    ?? /剩\s*([0-9]+(?:\.[0-9]+)?)\s*%/.exec(label);
  return match ? `${match[1]}%剩` : "";
}

function compactInlineDelta(label: string): string {
  const match = /稍快\s*([0-9]+(?:\.[0-9]+)?)\s*%/.exec(label);
  return match ? `余量低 ${match[1]}%` : "";
}

function withDetail(prefix: string, detail: string): string {
  return detail ? `${prefix}(${detail})` : prefix;
}

function stableWithDetail(detail: string): string {
  return detail ? `节奏稳(${detail})` : "节奏稳（正好贴线）";
}

export function compactResetCreditCountSuffix(summary: ResetCreditSummary): string {
  if (summary.availableCount > 0) {
    return ` · ${summary.availableCount}卡`;
  }
  return "";
}

export function compactResetCreditRateBarSuffix(summary: ResetCreditSummary, now = new Date()): string {
  const count = summary.availableCount ?? 0;
  if (count <= 0) {
    return "";
  }
  const countdown = nearestResetCreditExpiryCountdown(summary, now);
  return countdown ? ` · ${count}卡 · ${countdown}` : ` · ${count}卡`;
}

export function compactResetCreditStandaloneSuffix(summary: ResetCreditSummary, now = new Date()): string {
  const count = summary.availableCount ?? 0;
  if (count <= 0) {
    return "";
  }
  const countdown = nearestResetCreditExpiryCountdown(summary, now);
  return countdown ? ` · ${count}卡 · 近${countdown}到期` : ` · ${count}卡`;
}

export function compactFloatingUsageStatus(label: string, summary: ResetCreditSummary, now = new Date()): string {
  const pace = compactFloatingPaceLabel(label);
  return `${pace}${compactResetCreditStandaloneSuffix(summary, now)}`;
}

export function compactNearestResetCreditExpiryLabel(summary: ResetCreditSummary, now = new Date()): string {
  const countdown = nearestResetCreditExpiryCountdown(summary, now);
  return countdown ? ` · ${countdown}到期` : "";
}

function nearestResetCreditExpiryCountdown(summary: ResetCreditSummary, now = new Date()): string {
  const nearest = (summary.credits ?? [])
    .filter((credit) => isAvailableCredit(credit, now))
    .sort((left, right) => (expiresAtMillis(left) ?? Number.MAX_SAFE_INTEGER) - (expiresAtMillis(right) ?? Number.MAX_SAFE_INTEGER))[0];
  if (!nearest) {
    return "";
  }

  const expiresAt = expiresAtMillis(nearest);
  if (expiresAt === null) {
    return "";
  }

  const remaining = expiresAt - now.getTime();
  if (remaining <= 0) {
    return "";
  }

  if (remaining < HOUR_MS) {
    const minutes = Math.max(1, Math.ceil(remaining / (60 * 1000)));
    return `${minutes}m`;
  }

  if (remaining < DAY_MS) {
    const hours = Math.max(1, Math.ceil(remaining / HOUR_MS));
    return `${hours}h`;
  }

  const days = Math.max(1, Math.ceil(remaining / DAY_MS));
  return `${days}天`;
}

function isAvailableCredit(credit: ResetCreditDetail, now: Date): boolean {
  if (credit.status !== "可用") {
    return false;
  }
  if (credit.redeemedAt && credit.redeemedAt !== "未使用" && credit.redeemedAt !== "未提供") {
    return false;
  }
  const expiresAt = expiresAtMillis(credit);
  return expiresAt !== null && expiresAt > now.getTime();
}

function expiresAtMillis(credit: ResetCreditDetail): number | null {
  const value = credit.expiresAtUnix;
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return null;
  }
  return value > 10_000_000_000 ? value : value * 1000;
}
