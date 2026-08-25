import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("cache hit ranking keeps the outer ten-row surface and opens a searchable detail dialog", async () => {
  await withSsrModules(async (load) => {
    const { CacheHitRanking, CacheHitRankingDetail } = await load("/src/components/CacheHitRanking.tsx");
    const { buildCacheRankingItems } = await load("/src/components/cacheHitRanking/model.ts");
    const cacheUsage = {
      sessions: [
        {
          id: "low",
          title: "低命中会话",
          lastUpdated: "2026-07-07T09:00:00Z",
          breakdown: {
            inputTokens: 2_000,
            cachedInputTokens: 800,
            outputTokens: 0,
            totalTokens: 2_000,
            calls: 2,
          },
        },
        {
          id: "high",
          title: "高命中会话",
          lastUpdated: "2026-07-07T10:00:00Z",
          breakdown: {
            inputTokens: 2_000,
            cachedInputTokens: 1_960,
            outputTokens: 0,
            totalTokens: 2_000,
            calls: 2,
          },
        },
      ],
      turns: [],
    };
    const rankingItems = buildCacheRankingItems(cacheUsage, {
      scope: "sessions",
      sortOrder: "lowHit",
      excludesSingleTurnSessions: true,
      excludesFirstTurns: true,
      limit: Number.POSITIVE_INFINITY,
    });
    const stateProps = {
      cacheUsage,
      legacyItems: [],
      rankingItems,
      onClose: () => {},
      scope: "sessions",
      sortOrder: "lowHit",
      excludesSingleTurnSessions: true,
      excludesFirstTurns: true,
      onScopeChange: () => {},
      onSortOrderChange: () => {},
      onToggleSingleTurnSessions: () => {},
      onToggleFirstTurns: () => {},
    };

    const outerHtml = renderComponent(CacheHitRanking, { cacheUsage, legacyItems: [] });
    const detailHtml = renderComponent(CacheHitRankingDetail, stateProps);
    const legacyHtml = renderComponent(CacheHitRankingDetail, {
      ...stateProps,
      cacheUsage: { sessions: [], turns: [] },
      legacyItems: [
        {
          rank: 1,
          title: "旧低命中",
          subtitle: "旧数据",
          hitRate: 0.82,
          cachedTokens: 820,
          inputTokens: 1_000,
        },
      ],
      rankingItems: [],
    });
    const turnUsage = {
      sessions: [],
      turns: [
        {
          id: "turn-1",
          sessionId: "session-1",
          sessionTitle: "长问题会话",
          turnIndexInSession: 2,
          timestamp: "2026-07-07T11:00:00Z",
          userPrompt: "问：这是一个很长很长的问题，悬停后应该可以看到完整内容",
          assistantResponse: "答：这是一个很长很长的回答，悬停后应该可以看到完整内容",
          breakdown: {
            inputTokens: 2_000,
            cachedInputTokens: 800,
            outputTokens: 0,
            totalTokens: 2_000,
            calls: 1,
          },
        },
      ],
    };
    const turnItems = buildCacheRankingItems(turnUsage, {
      scope: "turns",
      sortOrder: "lowHit",
      excludesSingleTurnSessions: true,
      excludesFirstTurns: true,
      limit: Number.POSITIVE_INFINITY,
    });
    const turnHtml = renderComponent(CacheHitRankingDetail, {
      ...stateProps,
      cacheUsage: turnUsage,
      rankingItems: turnItems,
      scope: "turns",
    });

    assert.equal(outerHtml.match(/class="ranking-row"/g)?.length, 2);
    assert.match(outerHtml, /ranking-check/);
    assert.match(outerHtml, /低命中/);
    assert.match(outerHtml, /查看完整排行/);
    assert.match(outerHtml, /cache-hit-tone--orange/);
    assert.match(outerHtml, /cache-hit-tone--strong-blue/);
    assert.match(detailHtml, /role="dialog"/);
    assert.match(detailHtml, /type="search"/);
    assert.match(detailHtml, /搜索缓存命中排行/);
    assert.match(detailHtml, /已显示 2 \/ 共 2/);
    assert.match(legacyHtml, /cache-hit-tone--orange/);
    assert.match(legacyHtml, /已显示 1 \/ 共 1/);
    assert.doesNotMatch(legacyHtml, /继续加载/);
    assert.match(turnHtml, /class="ranking-row-copy"/);
    assert.match(turnHtml, /class="ranking-row-hover-card"/);
    assert.match(turnHtml, /悬停后应该可以看到完整内容/);
  });
});
