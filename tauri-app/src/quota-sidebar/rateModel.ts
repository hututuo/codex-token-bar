import { sanitizeRateFullScale, formatLiveRateValue } from "../components/liveRate/rateDisplay.ts";
import type { FloatingPanelSnapshot } from "../types/dashboard";

/** A measured zero is empty. Unknown/disabled rates never borrow the visual minimum fill. */
export function sidebarRatePercent(
  snapshot: Pick<FloatingPanelSnapshot, "tokensPerSecond" | "liveRateAvailable">,
  enabled: boolean,
  fullScale: number,
): number | null {
  if (!enabled || snapshot.liveRateAvailable !== true || !Number.isFinite(snapshot.tokensPerSecond) || snapshot.tokensPerSecond < 0) return null;
  return Math.min(100, Number(formatLiveRateValue(snapshot.tokensPerSecond)) / sanitizeRateFullScale(fullScale) * 100);
}
