import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";
import { Window } from "happy-dom";

test("cache advice distinguishes unknown, zero, and a single low request", async () => {
  await withSsrModules(async load => {
    const { CacheUsageNotice } = await load("/src/components/liveRate/CacheUsageNotice.tsx");
    const render = advice => renderToStaticMarkup(React.createElement(CacheUsageNotice, { advice }));
    assert.match(render(null), /等待缓存数据/);
    const sample = { threadId: "test-session", timestamp: 100, hitRate: 0, low: false };
    assert.match(render(sample), /0.0%/);
    assert.doesNotMatch(render(sample), /本次请求缓存命中偏低/);
    assert.match(render({ ...sample, low: true }), /本次请求缓存命中偏低/);
    assert.match(render({ ...sample, hitRate: NaN }), /等待缓存数据/);
    assert.match(render({ ...sample, hitRate: 2 }), /等待缓存数据/);
  });
});

test("compact projection preserves cache-only changes without precise data", async () => {
  await withSsrModules(async load => {
    const { floatingSnapshotForLiveRate } = await load("/src/surfaces/compactPanelSnapshotModel.ts");
    const advice = { threadId: "a", timestamp: 100, hitRate: .2, low: true };
    const live = { tokensPerSecond: 0, maxTokensPerSecond: 200, unreadSummary: { active: false }, warnings: [], cacheAdvice: advice };
    assert.deepEqual(floatingSnapshotForLiveRate(live, null).cacheAdvice, advice);
    assert.equal(floatingSnapshotForLiveRate({ ...live, cacheAdvice: null }, null).cacheAdvice, null);
  });
});

test("dismissal survives a low streak and the reminder switch persists", async () => {
  const window = new Window({ url: "http://localhost" });
  const keys = ["window", "document", "navigator", "HTMLElement", "Element", "Event", "localStorage", "IS_REACT_ACT_ENVIRONMENT"];
  const previous = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) Object.defineProperty(globalThis, key, { value: key === "IS_REACT_ACT_ENVIRONMENT" ? true : window[key], configurable: true, writable: true });
  try {
    await withSsrModules(async load => {
      const { CacheUsageNotice } = await load("/src/components/liveRate/CacheUsageNotice.tsx");
      const { createRoot } = await import("react-dom/client");
      const root = createRoot(window.document.body);
      const render = advice => React.act(async () => root.render(React.createElement(CacheUsageNotice, { advice })));
      const sample = { threadId: "a", timestamp: 100, hitRate: .1, low: true };
      try {
        await render(sample);
        assert.ok(window.document.querySelector('[role="status"]'));
        await React.act(async () => window.document.querySelector("button").click());
        await render({ ...sample, timestamp: 101 });
        assert.equal(window.document.querySelector('[role="status"]'), null);
        await render({ ...sample, low: false });
        await render({ ...sample, timestamp: 102 });
        assert.ok(window.document.querySelector('[role="status"]'));
        await React.act(async () => window.document.querySelector("input").click());
        assert.equal(window.localStorage.getItem("cacheHitAdviceEnabled"), "false");
        assert.equal(window.document.querySelector('[role="status"]'), null);
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    for (const [key, descriptor] of previous) descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key];
    window.close();
  }
});
