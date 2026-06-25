import type { TokenCacheUsage, TokenCacheBreakdown } from "../../types/usage";

export type CacheRankingScope = "sessions" | "turns";

export interface CacheRankingOptions {
  scope: CacheRankingScope;
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
        }))
    : cacheUsage.turns
        .filter((turn) => !options.excludesFirstTurns || turn.turnIndexInSession > 1)
        .map((turn): CacheRankingDisplayItem => ({
          id: turn.id,
          title: `问：${turn.userPrompt?.trim() || "暂无可见问题"}`,
          subtitle: `答：${turn.assistantResponse?.trim() || "暂无可见回答"}`,
          context: `${turn.sessionTitle || fallbackSessionTitle(turn.sessionId)} · 第 ${turn.turnIndexInSession} 轮 · ${formatMonthDayTime(turn.timestamp)}`,
          breakdown: turn.breakdown,
        }));

  return source
    .filter((item) => item.breakdown.inputTokens >= minimumInputTokens && item.breakdown.calls > 0)
    .sort((left, right) => {
      const rateDelta = cacheHitRate(left.breakdown) - cacheHitRate(right.breakdown);
      if (Math.abs(rateDelta) > 0.0001) return rateDelta;
      return uncachedInputTokens(right.breakdown) - uncachedInputTokens(left.breakdown);
    })
    .slice(0, limit);
}

export function rankingSubtitle(
  scope: CacheRankingScope,
  excludesSingleTurnSessions: boolean,
  excludesFirstTurns: boolean,
) {
  if (scope === "sessions") {
    return excludesSingleTurnSessions ? "低命中优先 · 已排除只有一轮的会话" : "低命中优先 · 包含单轮会话";
  }
  return excludesFirstTurns ? "低命中优先 · 已排除每个会话首轮" : "低命中优先 · 包含首轮";
}

export function cacheHitRate(breakdown: TokenCacheBreakdown) {
  return breakdown.inputTokens <= 0 ? 0 : breakdown.cachedInputTokens / breakdown.inputTokens;
}

export function uncachedInputTokens(breakdown: TokenCacheBreakdown) {
  return Math.max(0, breakdown.inputTokens - breakdown.cachedInputTokens);
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
