import type { ResetCreditSummary } from "../types/dashboard";

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
    return withDetail("节奏稳", delta);
  }
  if (normalized.includes("略有余量") || normalized.includes("正好贴着") || normalized.includes("贴近均速")) {
    return withDetail("节奏稳", delta || compactInlineDelta(normalized));
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
  return `余量${direction} ${match[2]}%`;
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

export function compactResetCreditLabel(summary: ResetCreditSummary): string {
  if (summary.availableCount > 0) {
    return ` · ${summary.availableCount}卡`;
  }
  return "";
}

export function compactFloatingUsageStatus(label: string, summary: ResetCreditSummary): string {
  const pace = compactFloatingPaceLabel(label);
  return `${pace}${compactResetCreditLabel(summary)}`;
}
