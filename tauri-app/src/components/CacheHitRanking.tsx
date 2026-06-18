import type { CacheHitRankingItem } from "../types/dashboard";
import { formatPercent, formatTokens } from "../utils/format";

interface CacheHitRankingProps {
  items: CacheHitRankingItem[];
}

export function CacheHitRanking({ items }: CacheHitRankingProps) {
  return (
    <section className="ranking-section" aria-label="缓存命中排行">
      <div className="section-title-row">
        <div>
          <h2>缓存命中排行</h2>
          <span>会话低命中优先 · 已排除单轮会话</span>
        </div>
      </div>

      <div className="ranking-list">
        {items.length === 0 ? (
          <article className="ranking-row ranking-row--empty">
            <strong>#</strong>
            <div>
              <h3>暂无可排行的缓存命中数据</h3>
              <span>需要至少两轮且输入 token 足够的会话</span>
            </div>
          </article>
        ) : (
          items.map((item) => (
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
          ))
        )}
      </div>
    </section>
  );
}
