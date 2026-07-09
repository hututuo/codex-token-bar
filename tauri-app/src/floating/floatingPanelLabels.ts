import type { FloatingPanelSnapshot } from "../types/dashboard";

type FloatingStatusSnapshot = Pick<
  FloatingPanelSnapshot,
  "trendLabel" | "liveRateStatusKind" | "liveRateStatusLabel" | "resetCreditLabel" | "resetCreditRateBarLabel" | "resetCreditStandaloneLabel"
>;

export function floatingRateBarStatusText(snapshot: FloatingStatusSnapshot): string {
  return `${floatingStatusBaseLabel(snapshot, "")}${snapshot.resetCreditRateBarLabel ?? snapshot.resetCreditLabel ?? ""}`;
}

export function floatingStandaloneStatusText(snapshot: FloatingStatusSnapshot): string {
  return `${floatingStatusBaseLabel(snapshot, "节奏待读取")}${snapshot.resetCreditStandaloneLabel ?? snapshot.resetCreditLabel ?? ""}`;
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
