import type { CSSProperties } from "react";
import type { LiveRateSnapshot } from "../../types/dashboard";

const ALPHA_UP = 0.28;
const ALPHA_DOWN = 0.18;
const ZERO_THRESHOLD = 0.05;
const MIN_VISIBLE_FILL = 0.03;
const SELECTED_SESSION_DISPLAY_CAP = 80;

export type RateDisplayScope = "selectedSession" | "allSessions";

export function sanitizeRateFullScale(value: number): number {
  if (!Number.isFinite(value)) {
    return 200;
  }
  return Math.min(400, Math.max(50, Math.round(value / 10) * 10));
}

export function rateFillScale(tokensPerSecond: number, fullScale: number): number {
  const scaleLimit = sanitizeRateFullScale(fullScale);
  if (!Number.isFinite(tokensPerSecond) || tokensPerSecond <= 0) {
    return MIN_VISIBLE_FILL;
  }
  const rawScale = Math.min(1, Math.max(0, tokensPerSecond / scaleLimit));
  return rawScale > 0 ? Math.max(MIN_VISIBLE_FILL, rawScale) : 0;
}

export function rateFillStyle(tokensPerSecond: number, fullScale: number): CSSProperties {
  return { "--rate-fill-scale": String(rateFillScale(tokensPerSecond, fullScale)) } as CSSProperties;
}

export function displayRawRate(raw: number, scope: RateDisplayScope): number {
  const value = Number.isFinite(raw) ? Math.max(0, raw) : 0;
  return scope === "selectedSession" ? Math.min(value, SELECTED_SESSION_DISPLAY_CAP) : value;
}

export function formatLiveRateValue(value: number): string {
  if (!Number.isFinite(value) || value < ZERO_THRESHOLD) {
    return "0.0";
  }
  return value.toFixed(1);
}

export function smoothLiveRateValue(previous: number, raw: number): number {
  if (!Number.isFinite(raw) || raw < ZERO_THRESHOLD) {
    return 0;
  }
  const normalizedPrevious = Number.isFinite(previous) ? Math.max(0, previous) : 0;
  const alpha = raw >= normalizedPrevious ? ALPHA_UP : ALPHA_DOWN;
  return normalizedPrevious + (raw - normalizedPrevious) * alpha;
}

export function smoothLiveRateSnapshot(
  snapshot: LiveRateSnapshot,
  previous: LiveRateSnapshot | null,
): LiveRateSnapshot {
  return {
    ...snapshot,
    tokensPerSecond: smoothLiveRateValue(
      previous?.tokensPerSecond ?? 0,
      displayRawRate(snapshot.tokensPerSecond, "allSessions"),
    ),
    selectedTokensPerSecond: smoothLiveRateValue(
      previous?.selectedTokensPerSecond ?? 0,
      displayRawRate(snapshot.selectedTokensPerSecond, "selectedSession"),
    ),
  };
}

export function liveRateDisplayBucket(snapshot: LiveRateSnapshot): string {
  return [
    formatLiveRateValue(snapshot.tokensPerSecond),
    formatLiveRateValue(snapshot.selectedTokensPerSecond),
    snapshot.threadTitle,
    snapshot.selectedThreadId ?? "",
    snapshot.selectedThreadTitle,
    snapshot.totalTokens,
    snapshot.totalTokensToday,
    snapshot.requestsToday,
    snapshot.preciseEnabled ? "precise" : "estimated",
    snapshot.unreadSummary.active ? snapshot.unreadSummary.count : 0,
    snapshot.warnings.map((warning) => `${warning.source}:${warning.message}`).join("~"),
  ].join("|");
}

export function changedLiveRateDisplayBucket(
  previousBucket: string,
  snapshot: LiveRateSnapshot,
): string | null {
  const bucket = liveRateDisplayBucket(snapshot);
  return bucket === previousBucket ? null : bucket;
}
