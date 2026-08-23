import type { FloatingPanelSnapshot } from "../types/dashboard";
import { radarEffectiveActionDisplayText, type CodexRadarSnapshot } from "../domain/codexRadar/model.ts";

type FloatingStatusSnapshot = Pick<
  FloatingPanelSnapshot,
  "trendLabel" | "liveRateStatusKind" | "liveRateStatusLabel" | "resetCreditLabel" | "resetCreditRateBarLabel" | "resetCreditStandaloneLabel"
>;

export function floatingRateBarStatusText(
  snapshot: FloatingStatusSnapshot,
  radarSnapshot?: CodexRadarSnapshot | null,
): string {
  const base = floatingStatusBaseLabel(snapshot, "");
  const suffix = snapshot.resetCreditRateBarLabel ?? snapshot.resetCreditLabel ?? "";
  return `${isSpeedWindow(radarSnapshot) ? speedWindowBaseLabel(base) : base}${suffix}`;
}

export function floatingStandaloneStatusText(
  snapshot: FloatingStatusSnapshot,
  radarSnapshot?: CodexRadarSnapshot | null,
): string {
  const base = floatingStatusBaseLabel(snapshot, "节奏待读取");
  const suffix = snapshot.resetCreditStandaloneLabel ?? snapshot.resetCreditLabel ?? "";
  return `${isSpeedWindow(radarSnapshot) ? speedWindowBaseLabel(base) : base}${suffix}`;
}

function isSpeedWindow(snapshot: CodexRadarSnapshot | null | undefined): boolean {
  return radarEffectiveActionDisplayText(snapshot) === "速登窗口";
}

function speedWindowBaseLabel(base: string): string {
  const normalized = base.trim();
  if (!normalized || normalized === "节奏待读取") {
    return "加快蹬";
  }
  const openingParenthesis = normalized.indexOf("(");
  if (openingParenthesis > 0) {
    return `加快蹬${normalized.slice(openingParenthesis)}`;
  }
  return `加快蹬 · ${normalized}`;
}

function floatingStatusBaseLabel(
  snapshot: Pick<FloatingPanelSnapshot, "trendLabel" | "liveRateStatusKind" | "liveRateStatusLabel">,
  fallback: string,
): string {
  if (snapshot.liveRateStatusKind === "failure" && snapshot.liveRateStatusLabel) {
    return snapshot.liveRateStatusLabel;
  }
  if (snapshot.trendLabel) {
    return snapshot.trendLabel;
  }
  return snapshot.liveRateStatusLabel || fallback;
}
