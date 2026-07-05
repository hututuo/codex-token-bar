import type { FloatingPanelSnapshot } from "../types/dashboard";

type FloatingStatusSnapshot = Pick<
  FloatingPanelSnapshot,
  "trendLabel" | "resetCreditLabel" | "resetCreditRateBarLabel" | "resetCreditStandaloneLabel"
>;

export function floatingRateBarStatusText(snapshot: FloatingStatusSnapshot): string {
  return `${snapshot.trendLabel}${snapshot.resetCreditRateBarLabel ?? snapshot.resetCreditLabel ?? ""}`;
}

export function floatingStandaloneStatusText(snapshot: FloatingStatusSnapshot): string {
  return `${snapshot.trendLabel || "节奏待读取"}${snapshot.resetCreditStandaloneLabel ?? snapshot.resetCreditLabel ?? ""}`;
}
