import type { CacheHitRankingItem, TokenCacheUsage, TokenCacheBreakdown } from "../../types/usage";

export type CacheRankingScope = "sessions" | "turns";
export type CacheRankingSortOrder = "lowHit" | "latest";

export interface CacheRankingOptions {
  scope: CacheRankingScope;
  sortOrder?: CacheRankingSortOrder;
  excludesSingleTurnSessions: boolean;
  excludesFirstTurns: boolean;
  minimumInputTokens?: number;
  limit?: number;
}

export interface CacheRankingDisplayItem {
  id: string;
  title: string;
  subtitle: string;
  context: string | null;
  breakdown: TokenCacheBreakdown;
  sortDate: string | null;
}

export function cacheRankingItemMatchesQuery(item: CacheRankingDisplayItem, query: string) {
  return cacheRankingSearchMatches([item.title, item.subtitle, item.context], query);
}

export function legacyCacheRankingItemMatchesQuery(item: CacheHitRankingItem, query: string) {
  return cacheRankingSearchMatches([item.title, item.subtitle], query);
}

export function buildCacheRankingItems(
  cacheUsage: TokenCacheUsage,
  options: CacheRankingOptions,
): CacheRankingDisplayItem[] {
  const minimumInputTokens = options.minimumInputTokens ?? 1_000;
  const limit = options.limit ?? 10;
  const source = options.scope === "sessions"
    ? cacheUsage.sessions
        .filter((session) => !options.excludesSingleTurnSessions || session.breakdown.calls > 1)
        .map((session): CacheRankingDisplayItem => ({
          id: session.id,
          title: session.title || fallbackSessionTitle(session.id),
          subtitle: sessionSubtitle(session.breakdown, session.lastUpdated),
          context: null,
          breakdown: session.breakdown,
          sortDate: session.lastUpdated,
        }))
    : cacheUsage.turns
        .filter((turn) => !options.excludesFirstTurns || turn.turnIndexInSession > 1)
        .map((turn): CacheRankingDisplayItem => ({
          id: turn.id,
          title: `问：${turn.userPrompt?.trim() || "暂无可见问题"}`,
          subtitle: `答：${turn.assistantResponse?.trim() || "暂无可见回答"}`,
          context: `${turn.sessionTitle || fallbackSessionTitle(turn.sessionId)} · 第 ${turn.turnIndexInSession} 轮 · ${formatMonthDayTime(turn.timestamp)}`,
          breakdown: turn.breakdown,
          sortDate: turn.timestamp,
        }));

  return source
    .filter((item) => item.breakdown.inputTokens >= minimumInputTokens && item.breakdown.calls > 0)
    .sort((left, right) => compareRankingItems(left, right, options.sortOrder ?? "lowHit"))
    .slice(0, limit);
}

export function rankingSubtitle(
  scope: CacheRankingScope,
  sortOrder: CacheRankingSortOrder,
  excludesSingleTurnSessions: boolean,
  excludesFirstTurns: boolean,
) {
  const prefix = sortOrder === "latest" ? "最新优先" : "低命中优先";
  if (scope === "sessions") {
    return excludesSingleTurnSessions ? `${prefix} · 已排除只有一轮的会话` : `${prefix} · 包含单轮会话`;
  }
  return excludesFirstTurns ? `${prefix} · 已排除每个会话首轮` : `${prefix} · 包含首轮`;
}

export function cacheHitRate(breakdown: TokenCacheBreakdown) {
  return breakdown.inputTokens <= 0 ? 0 : breakdown.cachedInputTokens / breakdown.inputTokens;
}

export function cacheHitTone(rate: number) {
  const normalized = clampRate(rate);
  if (normalized < 0.84) return "cache-hit-tone--orange";
  if (normalized < 0.88) return "cache-hit-tone--amber";
  if (normalized < 0.92) return "cache-hit-tone--teal";
  if (normalized < 0.96) return "cache-hit-tone--blue";
  return "cache-hit-tone--strong-blue";
}

export function cacheHitMeterWidthPercent(rate: number) {
  return Math.round(clampRate(rate) * 100);
}

export function uncachedInputTokens(breakdown: TokenCacheBreakdown) {
  return Math.max(0, breakdown.inputTokens - breakdown.cachedInputTokens);
}

function compareRankingItems(
  left: CacheRankingDisplayItem,
  right: CacheRankingDisplayItem,
  sortOrder: CacheRankingSortOrder,
) {
  if (sortOrder === "latest") {
    const dateDelta = compareSortDates(left.sortDate, right.sortDate);
    if (dateDelta !== 0) {
      return dateDelta;
    }
  }
  return compareLowHit(left.breakdown, right.breakdown);
}

function compareSortDates(left: string | null, right: string | null) {
  const leftTime = parsedTime(left);
  const rightTime = parsedTime(right);
  if (leftTime !== null && rightTime !== null && leftTime !== rightTime) {
    return rightTime - leftTime;
  }
  if (leftTime !== null && rightTime === null) {
    return -1;
  }
  if (leftTime === null && rightTime !== null) {
    return 1;
  }
  return 0;
}

function compareLowHit(left: TokenCacheBreakdown, right: TokenCacheBreakdown) {
  const rateDelta = cacheHitRate(left) - cacheHitRate(right);
  if (Math.abs(rateDelta) > 0.0001) return rateDelta;
  return uncachedInputTokens(right) - uncachedInputTokens(left);
}

function sessionSubtitle(breakdown: TokenCacheBreakdown, lastUpdated: string | null) {
  return `${breakdown.calls} 轮 · ${formatMonthDayTime(lastUpdated)}`;
}

function fallbackSessionTitle(sessionId: string) {
  const shortId = sessionId.slice(0, 8);
  return shortId ? `会话 ${shortId}` : "未知会话";
}

function formatMonthDayTime(value: string | null) {
  if (!value) return "未知时间";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "未知时间";
  const month = `${date.getMonth() + 1}`.padStart(2, "0");
  const day = `${date.getDate()}`.padStart(2, "0");
  const hour = `${date.getHours()}`.padStart(2, "0");
  const minute = `${date.getMinutes()}`.padStart(2, "0");
  return `${month}/${day} ${hour}:${minute}`;
}

function parsedTime(value: string | null) {
  if (!value) return null;
  const time = new Date(value).getTime();
  return Number.isNaN(time) ? null : time;
}

function clampRate(rate: number) {
  if (!Number.isFinite(rate)) {
    return 0;
  }
  return Math.min(1, Math.max(0, rate));
}

function cacheRankingSearchMatches(fields: Array<string | null | undefined>, query: string) {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  if (!normalizedQuery) return true;
  return fields.some((field) => field?.toLocaleLowerCase().includes(normalizedQuery));
}
