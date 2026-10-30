import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CacheHitRankingItem, TokenCacheUsage, CodexHomeSourceToken } from "../types/dashboard";
import { CacheTurnRequestsDialog } from "./cacheHitRanking/CacheTurnRequestsDialog";
import { formatPercent, formatTokens } from "../utils/format";
import {
  buildCacheRankingItems,
  compareRankingItems,
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
  sourceToken?: CodexHomeSourceToken | null;
  legacyItems?: CacheHitRankingItem[];
  aggregate?: boolean;
  localOnly?: boolean;
  additionalItems?: CacheRankingDisplayItem[];
  onOpenLocalSession?: (client: string, sessionID: string) => void;
}

interface CacheHitRankingDetailProps {
  cacheUsage: TokenCacheUsage;
  sourceToken?: CodexHomeSourceToken | null;
  legacyItems: CacheHitRankingItem[];
  rankingItems: CacheRankingDisplayItem[];
  aggregate?: boolean;
  localOnly?: boolean;
  onOpenLocalSession?: (client: string, sessionID: string) => void;
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
  scope: "turns" as CacheRankingScope,
  sortOrder: "latest" as CacheRankingSortOrder,
  excludesSingleTurnSessions: true,
  excludesFirstTurns: true,
};

const NO_ADDITIONAL_ITEMS: CacheRankingDisplayItem[] = [];

export function CacheHitRanking({ cacheUsage, legacyItems = [], sourceToken = null, aggregate = false, localOnly = false, additionalItems = NO_ADDITIONAL_ITEMS, onOpenLocalSession }: CacheHitRankingProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [scope, setScope] = useState<CacheRankingScope>(DEFAULT_RANKING_OPTIONS.scope);
  const [sortOrder, setSortOrder] = useState<CacheRankingSortOrder>(DEFAULT_RANKING_OPTIONS.sortOrder);
  const [excludesSingleTurnSessions, setExcludesSingleTurnSessions] = useState(
    DEFAULT_RANKING_OPTIONS.excludesSingleTurnSessions,
  );
  const [excludesFirstTurns, setExcludesFirstTurns] = useState(DEFAULT_RANKING_OPTIONS.excludesFirstTurns);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const hasOpenedRef = useRef(false);

  const rankingItems = useMemo(() => {
    const codex = buildCacheRankingItems(cacheUsage, {
      scope, sortOrder, excludesSingleTurnSessions, excludesFirstTurns,
      limit: Number.POSITIVE_INFINITY,
    });
    if (!aggregate) return codex;
    const original = codex.map(item => ({...item, id: "codex|" + item.id,
      title: "Codex · " + item.title, client: "codex"}));
    if (!cacheUsage.sessions.length && !cacheUsage.turns.length && !cacheUsage.rankingActiveSince) {
      original.push(...legacyItems.map(item => ({id: "codex|legacy|" + item.rank,
        title: "Codex · " + item.title, subtitle: item.subtitle, client: "codex", context: null, sortDate: null,
        breakdown: {inputTokens: item.inputTokens, cachedInputTokens: item.cachedTokens,
          outputTokens: 0, totalTokens: item.inputTokens, calls: 1}})));
    }
    return [...original, ...additionalItems].sort((a,b) => compareRankingItems(a,b,sortOrder));
  }, [cacheUsage, aggregate, legacyItems, additionalItems, excludesFirstTurns, excludesSingleTurnSessions, scope, sortOrder]);
  const hasCurrentRows = aggregate || Boolean(cacheUsage.rankingActiveSince) || cacheUsage.sessions.length > 0 || cacheUsage.turns.length > 0;
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
            {cacheUsage.rankingActiveSince && <p className="cache-ranking-scope-notice">已开启历史压缩，仅显示最近 7 天活跃会话。较早的历史会话可能已压缩。</p>}
            <span>{aggregate ? "缓存读取 / 输入 · 明细标注客户端及轮次或会话" : "整轮加权 · " + rankingSubtitle(scope, sortOrder, excludesSingleTurnSessions, excludesFirstTurns)}</span>
          </div>
          <div className="ranking-controls" aria-label="缓存命中排行控制">
            <CacheRankingControls
              localOnly={localOnly}
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
              : outerItems.map((item, index) => <CurrentRankingRow key={item.id} item={item} index={index} sourceToken={sourceToken} onOpenLocalSession={onOpenLocalSession} />)
          )}
        </div>
      </section>

      {isOpen ? (
        <CacheHitRankingDetail
          cacheUsage={cacheUsage}
          sourceToken={sourceToken}
          legacyItems={fallbackItems}
          rankingItems={rankingItems}
          aggregate={aggregate}
          localOnly={localOnly}
          onOpenLocalSession={onOpenLocalSession}
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
  sourceToken = null,
  legacyItems,
  rankingItems,
  aggregate = false,
  localOnly = false,
  onOpenLocalSession,
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
  const hasCurrentRows = aggregate || Boolean(cacheUsage.rankingActiveSince) || cacheUsage.sessions.length > 0 || cacheUsage.turns.length > 0;
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
            {cacheUsage.rankingActiveSince && <p className="cache-ranking-scope-notice">已开启历史压缩，仅显示最近 7 天活跃会话。较早的历史会话可能已压缩。</p>}
            <span>{aggregate ? "缓存读取 / 输入 · 明细标注客户端及轮次或会话" : "整轮加权 · " + rankingSubtitle(scope, sortOrder, excludesSingleTurnSessions, excludesFirstTurns)}</span>
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
                  localOnly={localOnly}
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
                  : visibleItems.map((item, index) => <CurrentRankingRow key={item.id} item={item} index={index} sourceToken={sourceToken} onOpenLocalSession={onOpenLocalSession} />)
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
  localOnly = false,
  scope,
  sortOrder,
  excludesSingleTurnSessions,
  excludesFirstTurns,
  onScopeChange,
  onSortOrderChange,
  onToggleSingleTurnSessions,
  onToggleFirstTurns,
}: {
  localOnly?: boolean;
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
      {!localOnly && <button
        type="button"
        className={`ranking-check ${scope === "sessions" ? "ranking-check--visible" : ""}`}
        onClick={scope === "sessions" ? onToggleSingleTurnSessions : onToggleFirstTurns}
        aria-pressed={scope === "sessions" ? excludesSingleTurnSessions : excludesFirstTurns}
      >
        <span>{(scope === "sessions" ? excludesSingleTurnSessions : excludesFirstTurns) ? "✓" : ""}</span>
        {scope === "sessions" ? "排除单轮会话" : "排除首轮"}
      </button>}
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
      {!localOnly && <div className="ranking-scope-tabs" role="tablist" aria-label="排行类型">
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
      </div>}
    </>
  );
}

function CurrentRankingRow({ item, index, sourceToken, onOpenLocalSession }: {
  item: CacheRankingDisplayItem; index: number; sourceToken?: CodexHomeSourceToken | null;
  onOpenLocalSession?: (client: string, sessionID: string) => void;
}) {
  const [showRequests, setShowRequests] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const hitRate = cacheHitRate(item.breakdown);
  const tone = cacheHitTone(hitRate);
  const closeRequests = useCallback(() => {
    setShowRequests(false);
    trigger.current?.focus();
  }, []);
  return (
    <>
      <article className="ranking-row">
        <strong>{index + 1}</strong>
        <RankingRowCopy title={item.title} subtitle={item.subtitle} context={item.context}
          requestSummary={item.turn && (item.turn.requestCount ?? 0) > 0
            ? `${item.turn.requestCount} 次请求 · 低命中 ${item.turn.lowHitCount ?? 0} 次 · 零命中 ${item.turn.zeroHitCount ?? 0} 次`
            : undefined} />
        <div className={`hit-meter ${tone}`}>
          <span style={{ width: `${cacheHitMeterWidthPercent(hitRate)}%` }} />
        </div>
        <em className={tone}>{(hitRate * 100).toFixed(2)}%</em>
        <span>未命中 {formatTokens(uncachedInputTokens(item.breakdown))}</span>
        <span>{formatTokens(item.breakdown.cachedInputTokens)} / {formatTokens(item.breakdown.inputTokens)}</span>
        {item.localSessionID && item.client && <button type="button" className="cache-request-open"
          onClick={() => onOpenLocalSession?.(item.client!,item.localSessionID!)}>请求明细 ›</button>}
        {item.turn && <button type="button" className="cache-request-open" ref={trigger}
          disabled={!sourceToken} onClick={() => setShowRequests(true)} aria-label="查看本轮每次请求的时间和用量">请求明细 ›</button>}
      </article>
      {showRequests && item.turn && sourceToken && <CacheTurnRequestsDialog
        turn={item.turn} sourceToken={sourceToken} onClose={closeRequests} />}
    </>
  );
}

function LegacyRankingRow({ item }: { item: CacheHitRankingItem }) {
  const tone = cacheHitTone(item.hitRate);
  return (
    <article className="ranking-row">
      <strong>{item.rank}</strong>
      <RankingRowCopy title={item.title} subtitle={item.subtitle} />
      <div className={`hit-meter ${tone}`}>
        <span style={{ width: `${cacheHitMeterWidthPercent(item.hitRate)}%` }} />
      </div>
      <em className={tone}>{formatPercent(item.hitRate)}</em>
      <span>{formatTokens(item.cachedTokens)} / {formatTokens(item.inputTokens)}</span>
    </article>
  );
}

function RankingRowCopy({
  requestSummary,
  context,
  subtitle,
  title,
}: {
  requestSummary?: string;
  context?: string | null;
  subtitle: string;
  title: string;
}) {
  const fullText = [title, subtitle, context].filter(Boolean).join("\n");
  return (
    <div
      aria-label={fullText}
      className="ranking-row-copy"
      tabIndex={0}
      title={fullText}
    >
      <h3>{title}</h3>
      <span className="ranking-row-answer">{subtitle}</span>
      {requestSummary && <small className="cache-request-counts">{requestSummary}</small>}
      {context ? <small>{context}</small> : null}
      <div aria-hidden="true" className="ranking-row-hover-card" role="tooltip">
        <strong>{title}</strong>
        <span>{subtitle}</span>
        {context ? <small>{context}</small> : null}
      </div>
    </div>
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
