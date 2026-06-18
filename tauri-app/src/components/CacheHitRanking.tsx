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
          <span>排除单轮和第一轮</span>
        </div>
        <div className="compact-checks">
          <label>
            <input defaultChecked type="checkbox" /> 排除单轮
          </label>
          <label>
            <input defaultChecked type="checkbox" /> 排除第一轮
          </label>
        </div>
      </div>

      <div className="ranking-list">
        {items.map((item) => (
          <article className="ranking-row" key={item.rank}>
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
        ))}
      </div>
    </section>
  );
}
