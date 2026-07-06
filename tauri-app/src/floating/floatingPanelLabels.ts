import type { FloatingPanelSnapshot } from "../types/dashboard";

type FloatingStatusSnapshot = Pick<
  FloatingPanelSnapshot,
  "trendLabel" | "liveRateStatusLabel" | "resetCreditLabel" | "resetCreditRateBarLabel" | "resetCreditStandaloneLabel"
>;

export function floatingRateBarStatusText(snapshot: FloatingStatusSnapshot): string {
  return `${snapshot.liveRateStatusLabel || snapshot.trendLabel}${snapshot.resetCreditRateBarLabel ?? snapshot.resetCreditLabel ?? ""}`;
}

export function floatingStandaloneStatusText(snapshot: FloatingStatusSnapshot): string {
  return `${snapshot.liveRateStatusLabel || snapshot.trendLabel || "节奏待读取"}${snapshot.resetCreditStandaloneLabel ?? snapshot.resetCreditLabel ?? ""}`;
}
