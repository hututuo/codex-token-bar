import { useMemo, useState } from "react";
import type { CacheHitRankingItem, TokenCacheUsage } from "../types/dashboard";
import { formatPercent, formatTokens } from "../utils/format";
import {
  buildCacheRankingItems,
  cacheHitRate,
  rankingSubtitle,
  uncachedInputTokens,
  type CacheRankingScope,
} from "./cacheHitRanking/model";

interface CacheHitRankingProps {
  cacheUsage: TokenCacheUsage;
  legacyItems?: CacheHitRankingItem[];
}

export function CacheHitRanking({ cacheUsage, legacyItems = [] }: CacheHitRankingProps) {
  const [scope, setScope] = useState<CacheRankingScope>("sessions");
  const [excludesSingleTurnSessions, setExcludesSingleTurnSessions] = useState(true);
  const [excludesFirstTurns, setExcludesFirstTurns] = useState(true);
  const rankingItems = useMemo(
    () => buildCacheRankingItems(cacheUsage, {
      scope,
      excludesSingleTurnSessions,
      excludesFirstTurns,
    }),
    [cacheUsage, excludesFirstTurns, excludesSingleTurnSessions, scope],
  );
  const fallbackItems = cacheUsage.sessions.length === 0 && cacheUsage.turns.length === 0 ? legacyItems : [];
  const hasRows = rankingItems.length > 0 || fallbackItems.length > 0;

  return (
    <section className="ranking-section" aria-label="缓存命中排行">
      <div className="section-title-row">
        <div>
          <h2>缓存命中排行</h2>
          <span>{rankingSubtitle(scope, excludesSingleTurnSessions, excludesFirstTurns)}</span>
        </div>
        <div className="ranking-controls" aria-label="缓存命中排行控制">
          <button
            type="button"
            className={`ranking-check ${scope === "sessions" ? "ranking-check--visible" : ""}`}
            onClick={() => scope === "sessions"
              ? setExcludesSingleTurnSessions((value) => !value)
              : setExcludesFirstTurns((value) => !value)}
            aria-pressed={scope === "sessions" ? excludesSingleTurnSessions : excludesFirstTurns}
          >
            <span>{(scope === "sessions" ? excludesSingleTurnSessions : excludesFirstTurns) ? "✓" : ""}</span>
            {scope === "sessions" ? "排除单轮会话" : "排除首轮"}
          </button>
          <div className="ranking-scope-tabs" role="tablist" aria-label="排行类型">
            <button
              type="button"
              className={scope === "sessions" ? "is-active" : ""}
              onClick={() => setScope("sessions")}
              role="tab"
              aria-selected={scope === "sessions"}
            >
              会话
            </button>
            <button
              type="button"
              className={scope === "turns" ? "is-active" : ""}
              onClick={() => setScope("turns")}
              role="tab"
              aria-selected={scope === "turns"}
            >
              单轮
            </button>
          </div>
        </div>
      </div>

      <div className="ranking-list">
        {!hasRows ? (
          <article className="ranking-row ranking-row--empty">
            <strong>#</strong>
            <div>
              <h3>暂无可排行的缓存命中数据</h3>
              <span>需要至少两轮且输入 token 足够的会话</span>
            </div>
          </article>
        ) : (
          fallbackItems.length > 0 ? fallbackItems.map((item) => (
            <article className="ranking-row" key={`${item.rank}-${item.title}`}>
              <strong>{item.rank}</strong>
              <div>
                <h3>{item.title}</h3>
                <span>{item.subtitle}</span>
              </div>
              <div className="hit-meter">
                <span style={{ width: `${Math.round(item.hitRate * 100)}%` }} />
              </div>
              <em>{formatPercent(item.hitRate)}</em>
              <span>{formatTokens(item.cachedTokens)} / {formatTokens(item.inputTokens)}</span>
            </article>
          )) : rankingItems.map((item, index) => (
            <article className="ranking-row" key={item.id}>
              <strong>{index + 1}</strong>
              <div>
                <h3>{item.title}</h3>
                <span>{item.subtitle}</span>
                {item.context ? <small>{item.context}</small> : null}
              </div>
              <div className="hit-meter">
                <span style={{ width: `${Math.round(cacheHitRate(item.breakdown) * 100)}%` }} />
              </div>
              <em>{formatPercent(cacheHitRate(item.breakdown))}</em>
              <span>
                未命中 {formatTokens(uncachedInputTokens(item.breakdown))}
              </span>
              <span>{formatTokens(item.breakdown.cachedInputTokens)} / {formatTokens(item.breakdown.inputTokens)}</span>
            </article>
          ))
        )}
      </div>
    </section>
  );
}
