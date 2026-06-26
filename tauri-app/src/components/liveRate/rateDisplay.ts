import type { CSSProperties } from "react";
import type { LiveRateSnapshot } from "../../types/dashboard";

const ALPHA_UP = 0.28;
const ALPHA_DOWN = 0.18;
const ZERO_THRESHOLD = 0.05;
const MIN_VISIBLE_FILL = 0.03;

export function sanitizeRateFullScale(value: number): number {
  if (!Number.isFinite(value)) {
    return 200;
  }
  return Math.min(400, Math.max(50, Math.round(value / 10) * 10));
}

export function rateFillScale(tokensPerSecond: number, fullScale: number): number {
  const scaleLimit = sanitizeRateFullScale(fullScale);
  if (!Number.isFinite(tokensPerSecond) || tokensPerSecond <= 0) {
    return 0;
  }
  const rawScale = Math.min(1, Math.max(0, tokensPerSecond / scaleLimit));
  return rawScale > 0 ? Math.max(MIN_VISIBLE_FILL, rawScale) : 0;
}

export function rateFillStyle(tokensPerSecond: number, fullScale: number): CSSProperties {
  return { "--rate-fill-scale": String(rateFillScale(tokensPerSecond, fullScale)) } as CSSProperties;
}

export function formatLiveRateValue(value: number): string {
  if (!Number.isFinite(value) || value < ZERO_THRESHOLD) {
    return "0.0";
  }
  return value < 10 ? value.toFixed(1) : String(Math.round(value));
}

export function smoothLiveRateValue(previous: number, raw: number): number {
  if (!Number.isFinite(raw) || raw < ZERO_THRESHOLD) {
    return 0;
  }
  if (!Number.isFinite(previous) || previous < ZERO_THRESHOLD) {
    return raw;
  }
  const alpha = raw > previous ? ALPHA_UP : ALPHA_DOWN;
  return previous + (raw - previous) * alpha;
}

export function smoothLiveRateSnapshot(
  snapshot: LiveRateSnapshot,
  previous: LiveRateSnapshot | null,
): LiveRateSnapshot {
  return {
    ...snapshot,
    tokensPerSecond: smoothLiveRateValue(previous?.tokensPerSecond ?? 0, snapshot.tokensPerSecond),
    selectedTokensPerSecond: smoothLiveRateValue(
      previous?.selectedTokensPerSecond ?? 0,
      snapshot.selectedTokensPerSecond,
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
    snapshot.warnings.length,
  ].join("|");
}
