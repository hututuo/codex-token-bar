import type { CacheUsageAdvice } from "../../types/live";

export function cacheAdviceTitle(advice: CacheUsageAdvice): string {
  return advice.threadTitle?.replace(/\s+/g, " ").trim() || "无标题会话";
}

export function cacheAdviceID(advice: CacheUsageAdvice): string {
  return `${advice.threadId}:${advice.timestamp}`;
}

export function hasValidCacheHitRate(advice?: CacheUsageAdvice | null): advice is CacheUsageAdvice {
  return !!advice && Number.isFinite(advice.hitRate) && advice.hitRate >= 0 && advice.hitRate <= 1;
}

export function cacheAdviceWarning(advice: CacheUsageAdvice | null | undefined, enabled: boolean,
  dismissedID = "", now = Date.now() / 1000): CacheUsageAdvice | null {
  return enabled && hasValidCacheHitRate(advice) && advice.low
    && Number.isFinite(advice.timestamp) && advice.timestamp >= 0
    && now >= advice.timestamp && now - advice.timestamp <= 120
    && cacheAdviceID(advice) !== dismissedID ? advice : null;
}
