import type { ResetCreditSummary } from "../types/dashboard";

export function compactFloatingPaceLabel(label: string): string {
  const normalized = label.trim();
  if (!normalized || normalized === "额度待读取") {
    return normalized;
  }
  if (normalized.includes("用得太快") || normalized.includes("用得偏快") || normalized.includes("慢一点")) {
    return "慢一点";
  }
  if (normalized.includes("余量很足") || normalized.includes("使劲蹬")) {
    return "余量足";
  }
  if (normalized.includes("节奏很好") || normalized.includes("可以冲")) {
    return "节奏好";
  }
  if (normalized.includes("略有余量")) {
    return "略有余量";
  }
  return normalized.replace(/（[^）]*）/g, "").trim();
}

export function compactResetCreditLabel(summary: ResetCreditSummary): string {
  if (summary.availableCount > 0) {
    return `${summary.availableCount}卡`;
  }
  if (summary.status.includes("待读取")) {
    return "卡--";
  }
  return "0卡";
}
