import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CacheHitRankingItem, TokenCacheUsage } from "../types/dashboard";
import { formatPercent, formatTokens } from "../utils/format";
import {
  buildCacheRankingItems,
  cacheHitMeterWidthPercent,
  cacheHitRate,
  cacheHitTone,
  cacheRankingItemMatchesQuery,
  legacyCacheRankingItemMatchesQuery,
  rankingSubtitle,
  uncachedInputTokens,
  type CacheRankingDisplayItem,
  type CacheRankingScope,
  type CacheRankingSortOrder,
} from "./cacheHitRanking/model";

export const CACHE_RANKING_PAGE_SIZE = 10;

interface CacheHitRankingProps {
  cacheUsage: TokenCacheUsage;
  legacyItems?: CacheHitRankingItem[];
}

interface CacheHitRankingDetailProps {
  cacheUsage: TokenCacheUsage;
  legacyItems: CacheHitRankingItem[];
  rankingItems: CacheRankingDisplayItem[];
  onClose: () => void;
  scope: CacheRankingScope;
  sortOrder: CacheRankingSortOrder;
  excludesSingleTurnSessions: boolean;
  excludesFirstTurns: boolean;
  onScopeChange: (scope: CacheRankingScope) => void;
  onSortOrderChange: (sortOrder: CacheRankingSortOrder) => void;
  onToggleSingleTurnSessions: () => void;
  onToggleFirstTurns: () => void;
}

const DEFAULT_RANKING_OPTIONS = {
  scope: "sessions" as CacheRankingScope,
  sortOrder: "lowHit" as CacheRankingSortOrder,
  excludesSingleTurnSessions: true,
  excludesFirstTurns: true,
};

export function CacheHitRanking({ cacheUsage, legacyItems = [] }: CacheHitRankingProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [scope, setScope] = useState<CacheRankingScope>(DEFAULT_RANKING_OPTIONS.scope);
  const [sortOrder, setSortOrder] = useState<CacheRankingSortOrder>(DEFAULT_RANKING_OPTIONS.sortOrder);
  const [excludesSingleTurnSessions, setExcludesSingleTurnSessions] = useState(
    DEFAULT_RANKING_OPTIONS.excludesSingleTurnSessions,
  );
  const [excludesFirstTurns, setExcludesFirstTurns] = useState(DEFAULT_RANKING_OPTIONS.excludesFirstTurns);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const hasOpenedRef = useRef(false);

  const rankingItems = useMemo(
    () => buildCacheRankingItems(cacheUsage, {
      scope,
      sortOrder,
      excludesSingleTurnSessions,
      excludesFirstTurns,
      // The native cacheUsage payload already contains the candidate pool. The
      // outer surface and detail overlay slice this memoized result locally.
      limit: Number.POSITIVE_INFINITY,
    }),
    [cacheUsage, excludesFirstTurns, excludesSingleTurnSessions, scope, sortOrder],
  );
  const hasCurrentRows = cacheUsage.sessions.length > 0 || cacheUsage.turns.length > 0;
  const fallbackItems = hasCurrentRows ? [] : legacyItems;
  const outerItems = hasCurrentRows ? rankingItems.slice(0, CACHE_RANKING_PAGE_SIZE) : [];
  const outerFallbackItems = hasCurrentRows ? [] : fallbackItems.slice(0, CACHE_RANKING_PAGE_SIZE);
  const hasRows = outerItems.length > 0 || outerFallbackItems.length > 0;

  const open = useCallback(() => {
    hasOpenedRef.current = true;
    setIsOpen(true);
  }, []);
  const close = useCallback(() => setIsOpen(false), []);

  useEffect(() => {
    if (!isOpen && hasOpenedRef.current) {
      triggerRef.current?.focus();
    }
  }, [isOpen]);

  return (
    <>
      <section className="ranking-section" aria-label="缓存命中排行">
        <div className="section-title-row cache-ranking-section-title-row">
          <div>
            <h2>缓存命中排行</h2>
            <span>{rankingSubtitle(scope, sortOrder, excludesSingleTurnSessions, excludesFirstTurns)}</span>
          </div>
          <div className="ranking-controls" aria-label="缓存命中排行控制">
            <CacheRankingControls
              scope={scope}
              sortOrder={sortOrder}
              excludesSingleTurnSessions={excludesSingleTurnSessions}
              excludesFirstTurns={excludesFirstTurns}
              onScopeChange={setScope}
              onSortOrderChange={setSortOrder}
              onToggleSingleTurnSessions={() => setExcludesSingleTurnSessions((value) => !value)}
              onToggleFirstTurns={() => setExcludesFirstTurns((value) => !value)}
            />
            <button
              type="button"
              className="cache-ranking-open-button"
              onClick={open}
              ref={triggerRef}
              aria-haspopup="dialog"
              aria-expanded={isOpen}
            >
              查看完整排行
            </button>
          </div>
        </div>

        <div className="ranking-list">
          {!hasRows ? (
            <EmptyRankingRow />
          ) : (
            outerFallbackItems.length > 0
              ? outerFallbackItems.map((item) => <LegacyRankingRow key={`${item.rank}-${item.title}`} item={item} />)
              : outerItems.map((item, index) => <CurrentRankingRow key={item.id} item={item} index={index} />)
          )}
        </div>
      </section>

      {isOpen ? (
        <CacheHitRankingDetail
          cacheUsage={cacheUsage}
          legacyItems={fallbackItems}
          rankingItems={rankingItems}
          onClose={close}
          scope={scope}
          sortOrder={sortOrder}
          excludesSingleTurnSessions={excludesSingleTurnSessions}
          excludesFirstTurns={excludesFirstTurns}
          onScopeChange={setScope}
          onSortOrderChange={setSortOrder}
          onToggleSingleTurnSessions={() => setExcludesSingleTurnSessions((value) => !value)}
          onToggleFirstTurns={() => setExcludesFirstTurns((value) => !value)}
        />
      ) : null}
    </>
  );
}

export function CacheHitRankingDetail({
  cacheUsage,
  legacyItems,
  rankingItems,
  onClose,
  scope,
  sortOrder,
  excludesSingleTurnSessions,
  excludesFirstTurns,
  onScopeChange,
  onSortOrderChange,
  onToggleSingleTurnSessions,
  onToggleFirstTurns,
}: CacheHitRankingDetailProps) {
  const [visibleCount, setVisibleCount] = useState(CACHE_RANKING_PAGE_SIZE);
  const [searchQuery, setSearchQuery] = useState("");
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const searchedItems = useMemo(
    () => rankingItems.filter((item) => cacheRankingItemMatchesQuery(item, searchQuery)),
    [rankingItems, searchQuery],
  );
  const searchedLegacyItems = useMemo(
    () => legacyItems.filter((item) => legacyCacheRankingItemMatchesQuery(item, searchQuery)),
    [legacyItems, searchQuery],
  );
  const hasCurrentRows = cacheUsage.sessions.length > 0 || cacheUsage.turns.length > 0;
  const filteredItems = hasCurrentRows ? searchedItems : [];
  const filteredFallbackItems = hasCurrentRows ? [] : searchedLegacyItems;
  const totalCount = hasCurrentRows ? filteredItems.length : filteredFallbackItems.length;
  const displayedCount = Math.min(visibleCount, totalCount);
  const hasRows = totalCount > 0;
  const visibleItems = filteredItems.slice(0, visibleCount);
  const visibleFallbackItems = filteredFallbackItems.slice(0, visibleCount);

  useEffect(() => {
    setVisibleCount(CACHE_RANKING_PAGE_SIZE);
  }, [excludesFirstTurns, excludesSingleTurnSessions, scope, sortOrder, searchQuery]);

  useEffect(() => {
    closeButtonRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  return (
    <div
      className="codex-radar-detail-layer cache-ranking-detail-layer"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
    >
      <div
        className="codex-radar-detail-card cache-ranking-detail-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby="cache-hit-ranking-detail-title"
      >
        <div className="codex-radar-detail-head cache-ranking-detail-head">
          <div>
            <strong id="cache-hit-ranking-detail-title">缓存命中排行</strong>
            <span>{rankingSubtitle(scope, sortOrder, excludesSingleTurnSessions, excludesFirstTurns)}</span>
          </div>
          <button
            aria-label="关闭缓存命中排行详情"
            className="codex-radar-detail-close"
            onClick={onClose}
            ref={closeButtonRef}
            type="button"
          >
            ×
          </button>
        </div>

        <div className="codex-radar-detail-scroll cache-ranking-detail-scroll">
          <div className="cache-ranking-detail-content">
            <div className="cache-ranking-detail-toolbar">
              <div className="ranking-controls" aria-label="缓存命中排行控制">
                <CacheRankingControls
                  scope={scope}
                  sortOrder={sortOrder}
                  excludesSingleTurnSessions={excludesSingleTurnSessions}
                  excludesFirstTurns={excludesFirstTurns}
                  onScopeChange={(nextScope) => {
                    setVisibleCount(CACHE_RANKING_PAGE_SIZE);
                    onScopeChange(nextScope);
                  }}
                  onSortOrderChange={(nextSortOrder) => {
                    setVisibleCount(CACHE_RANKING_PAGE_SIZE);
                    onSortOrderChange(nextSortOrder);
                  }}
                  onToggleSingleTurnSessions={() => {
                    setVisibleCount(CACHE_RANKING_PAGE_SIZE);
                    onToggleSingleTurnSessions();
                  }}
                  onToggleFirstTurns={() => {
                    setVisibleCount(CACHE_RANKING_PAGE_SIZE);
                    onToggleFirstTurns();
                  }}
                />
              </div>
              <label className="cache-ranking-search">
                <span>搜索排行</span>
                <input
                  type="search"
                  value={searchQuery}
                  onChange={(event) => {
                    setSearchQuery(event.target.value);
                    setVisibleCount(CACHE_RANKING_PAGE_SIZE);
                  }}
                  placeholder="标题、问答或会话上下文"
                  aria-label="搜索缓存命中排行"
                />
              </label>
              <span className="cache-ranking-detail-count" aria-live="polite">
                已显示 {displayedCount} / 共 {totalCount}
              </span>
            </div>

            <div className="ranking-list">
              {!hasRows ? (
                <EmptyRankingRow searchQuery={searchQuery} />
              ) : (
                filteredFallbackItems.length > 0
                  ? visibleFallbackItems.map((item) => <LegacyRankingRow key={`${item.rank}-${item.title}`} item={item} />)
                  : visibleItems.map((item, index) => <CurrentRankingRow key={item.id} item={item} index={index} />)
              )}
            </div>

            {displayedCount < totalCount ? (
              <button
                type="button"
                className="cache-ranking-load-more"
                onClick={() => setVisibleCount((value) => Math.min(value + CACHE_RANKING_PAGE_SIZE, totalCount))}
              >
                继续加载 {Math.min(CACHE_RANKING_PAGE_SIZE, totalCount - displayedCount)} 条
              </button>
            ) : null}
          </div>
        </div>
      </div>
    </div>
  );
}

function CacheRankingControls({
  scope,
  sortOrder,
  excludesSingleTurnSessions,
  excludesFirstTurns,
  onScopeChange,
  onSortOrderChange,
  onToggleSingleTurnSessions,
  onToggleFirstTurns,
}: {
  scope: CacheRankingScope;
  sortOrder: CacheRankingSortOrder;
  excludesSingleTurnSessions: boolean;
  excludesFirstTurns: boolean;
  onScopeChange: (scope: CacheRankingScope) => void;
  onSortOrderChange: (sortOrder: CacheRankingSortOrder) => void;
  onToggleSingleTurnSessions: () => void;
  onToggleFirstTurns: () => void;
}) {
  return (
    <>
      <button
        type="button"
        className={`ranking-check ${scope === "sessions" ? "ranking-check--visible" : ""}`}
        onClick={scope === "sessions" ? onToggleSingleTurnSessions : onToggleFirstTurns}
        aria-pressed={scope === "sessions" ? excludesSingleTurnSessions : excludesFirstTurns}
      >
        <span>{(scope === "sessions" ? excludesSingleTurnSessions : excludesFirstTurns) ? "✓" : ""}</span>
        {scope === "sessions" ? "排除单轮会话" : "排除首轮"}
      </button>
      <div className="ranking-scope-tabs" role="tablist" aria-label="排序方式">
        <button
          type="button"
          className={sortOrder === "lowHit" ? "is-active" : ""}
          onClick={() => onSortOrderChange("lowHit")}
          role="tab"
          aria-selected={sortOrder === "lowHit"}
        >
          低命中
        </button>
        <button
          type="button"
          className={sortOrder === "latest" ? "is-active" : ""}
          onClick={() => onSortOrderChange("latest")}
          role="tab"
          aria-selected={sortOrder === "latest"}
        >
          最新
        </button>
      </div>
      <div className="ranking-scope-tabs" role="tablist" aria-label="排行类型">
        <button
          type="button"
          className={scope === "sessions" ? "is-active" : ""}
          onClick={() => onScopeChange("sessions")}
          role="tab"
          aria-selected={scope === "sessions"}
        >
          会话
        </button>
        <button
          type="button"
          className={scope === "turns" ? "is-active" : ""}
          onClick={() => onScopeChange("turns")}
          role="tab"
          aria-selected={scope === "turns"}
        >
          单轮
        </button>
      </div>
    </>
  );
}

function CurrentRankingRow({ item, index }: { item: CacheRankingDisplayItem; index: number }) {
  const hitRate = cacheHitRate(item.breakdown);
  const tone = cacheHitTone(hitRate);
  return (
    <article className="ranking-row">
      <strong>{index + 1}</strong>
      <div>
        <h3>{item.title}</h3>
        <span>{item.subtitle}</span>
        {item.context ? <small>{item.context}</small> : null}
      </div>
      <div className={`hit-meter ${tone}`}>
        <span style={{ width: `${cacheHitMeterWidthPercent(hitRate)}%` }} />
      </div>
      <em className={tone}>{formatPercent(hitRate)}</em>
      <span>未命中 {formatTokens(uncachedInputTokens(item.breakdown))}</span>
      <span>{formatTokens(item.breakdown.cachedInputTokens)} / {formatTokens(item.breakdown.inputTokens)}</span>
    </article>
  );
}

function LegacyRankingRow({ item }: { item: CacheHitRankingItem }) {
  const tone = cacheHitTone(item.hitRate);
  return (
    <article className="ranking-row">
      <strong>{item.rank}</strong>
      <div>
        <h3>{item.title}</h3>
        <span>{item.subtitle}</span>
      </div>
      <div className={`hit-meter ${tone}`}>
        <span style={{ width: `${cacheHitMeterWidthPercent(item.hitRate)}%` }} />
      </div>
      <em className={tone}>{formatPercent(item.hitRate)}</em>
      <span>{formatTokens(item.cachedTokens)} / {formatTokens(item.inputTokens)}</span>
    </article>
  );
}

function EmptyRankingRow({ searchQuery = "" }: { searchQuery?: string }) {
  return (
    <article className="ranking-row ranking-row--empty">
      <strong>#</strong>
      <div>
        <h3>{searchQuery ? "没有匹配的缓存命中数据" : "暂无可排行的缓存命中数据"}</h3>
        <span>{searchQuery ? "请尝试其他标题、问答或会话上下文" : "需要至少两轮且输入 token 足够的会话"}</span>
      </div>
    </article>
  );
}
