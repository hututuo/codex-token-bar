import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("cache hit ranking renders hit-rate tone classes for current and legacy rows", async () => {
  await withSsrModules(async (load) => {
    const { CacheHitRanking } = await load("/src/components/CacheHitRanking.tsx");

    const currentHtml = renderComponent(CacheHitRanking, {
      cacheUsage: {
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
      },
      legacyItems: [],
    });

    const legacyHtml = renderComponent(CacheHitRanking, {
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
    });

    assert.match(currentHtml, /cache-hit-tone--orange/);
    assert.match(currentHtml, /cache-hit-tone--strong-blue/);
    assert.match(currentHtml, /<em class=\"cache-hit-tone--orange\">40%<\/em>/);
    assert.match(currentHtml, /<em class=\"cache-hit-tone--strong-blue\">98%<\/em>/);
    assert.match(legacyHtml, /cache-hit-tone--orange/);
    assert.match(legacyHtml, /hit-meter cache-hit-tone--orange/);
  });
});
