import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { cacheAdviceTitle, cacheAdviceWarning, cacheAdviceID } from "../components/liveRate/cacheAdvicePresentation.ts";
import { initialSidebarState, sidebarReducer } from "./model.ts";

test("cache reminder requires a fresh valid request and uses a title rather than ID", () => {
  const advice = { threadId: "private-id", threadTitle: "  修复\n 金额显示  ", timestamp: 100, hitRate: 0, low: true };
  assert.equal(cacheAdviceTitle(advice), "修复 金额显示");
  assert.equal(cacheAdviceTitle({ ...advice, threadTitle: " \n " }), "无标题会话");
  assert.equal(cacheAdviceTitle({ ...advice, threadTitle: undefined }), "无标题会话");
  assert.equal(cacheAdviceWarning(advice, true, "", 100), advice);
  for (const patch of [{ hitRate: NaN }, { hitRate: 2 }, { hitRate: -1 }, { low: false }, { timestamp: 101 }, { timestamp: -21 }]) {
    assert.equal(cacheAdviceWarning({ ...advice, ...patch }, true, "", 100), null);
  }
  assert.equal(cacheAdviceWarning(advice, false, "", 100), null);
  assert.equal(cacheAdviceWarning(advice, true, cacheAdviceID(advice), 100), null);
  assert.equal(cacheAdviceWarning(advice, true, "", 221), null);
});

test("an alert opens and holds only level two, preserving selected details and pin", () => {
  let state = sidebarReducer(initialSidebarState, { type: "cache-advice", id: "a:100" });
  assert.equal(state.mode, "hover");
  assert.equal(state.pinned, false);
  assert.equal(sidebarReducer(state, { type: "leave" }), state);
  state = sidebarReducer(state, { type: "cache-advice", id: null });
  assert.equal(sidebarReducer(state, { type: "leave" }).mode, "rest");
  state = sidebarReducer(initialSidebarState, { type: "open", tab: "running" });
  state = sidebarReducer(state, { type: "pin" });
  state = sidebarReducer(state, { type: "cache-advice", id: "a:101" });
  assert.equal(state.mode, "detail");
  assert.equal(state.tab, "running");
  assert.equal(state.pinned, true);
  assert.equal(sidebarReducer(state, { type: "close" }).cacheNoticeID, undefined);
  assert.equal(sidebarReducer(state, { type: "drag" }).cacheNoticeID, undefined);
});

test("live sidebar alerts expand, show titles, open details and share dismissal and opt-out", async () => {
  const window = new Window({ url: "http://localhost" });
  const keys = ["window", "document", "navigator", "HTMLElement", "Element", "Event", "localStorage", "IS_REACT_ACT_ENVIRONMENT"];
  const previous = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) Object.defineProperty(globalThis, key, { value: key === "IS_REACT_ACT_ENVIRONMENT" ? true : window[key], configurable: true, writable: true });
  try {
    await withSsrModules(async load => {
      const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
      const { useSidebarCacheAdvice } = await load("/src/quota-sidebar/useSidebarCacheAdvice.ts");
      const { useCacheUsageAdvice } = await load("/src/components/liveRate/useCacheUsageAdvice.ts");
      const { CacheUsageNotice } = await load("/src/components/liveRate/CacheUsageNotice.tsx");
      const { createRoot } = await import("react-dom/client");
      const root = createRoot(window.document.body);
      let state, dispatch;
      function Harness({ advice, available = true, dragging = false }) {
        [state, dispatch] = React.useReducer(sidebarReducer, initialSidebarState);
        const { warning } = useCacheUsageAdvice(advice, available);
        useSidebarCacheAdvice(warning, dispatch, dragging);
        const data = { snapshot: { cacheAdvice: advice, liveRateAvailable: available, todayModelBreakdowns: [], fiveHourAvailability: "absent", sevenDayAvailability: "unavailable", sevenDayRemainingPercent: null }, runningThreads: { status: "ready", total: 0 }, quota: { quota: {} } };
        return React.createElement(React.Fragment, null,
          React.createElement(SidebarRailContent, { data, state, onOpen: (tab, section) => dispatch({ type: "open", tab, section }) }),
          React.createElement(CacheUsageNotice, { advice }));
      }
      const render = (advice, props = {}) => React.act(async () => root.render(React.createElement(Harness, { advice, ...props })));
      const advice = { threadId: "private-id", threadTitle: "修复金额提示", timestamp: Date.now() / 1000 - 10, hitRate: .12, low: true };
      try {
        await render(null);
        assert.equal(state.mode, "rest");
        await render(advice);
        assert.equal(state.mode, "hover");
        assert.ok(window.document.querySelector(".qs-cache-indicator"));
        assert.equal(window.document.querySelector(".qs-cache-title").textContent, "修复金额提示");
        assert.match(window.document.querySelector(".qs-cache-notice").textContent, /12.0%/);
        await React.act(async () => dispatch({ type: "leave" }));
        assert.equal(state.mode, "hover");
        await React.act(async () => window.document.querySelector(".qs-cache-open").click());
        assert.equal(state.mode, "detail");
        assert.equal(state.section, "usage");
        await React.act(async () => window.document.querySelector(".qs-cache-dismiss").click());
        assert.equal(window.document.querySelector(".qs-cache-notice"), null);
        assert.equal(window.document.querySelector(".qs-cache-indicator"), null);
        assert.equal(window.document.querySelector('[role="status"]'), null);
        await React.act(async () => dispatch({ type: "leave" }));
        await render({ ...advice });
        assert.equal(state.mode, "rest");
        await render({ ...advice, timestamp: advice.timestamp + 1 }, { dragging: true });
        assert.equal(state.mode, "rest");
        await render({ ...advice, timestamp: advice.timestamp + 1 });
        assert.equal(state.mode, "hover");
        await React.act(async () => window.document.querySelector("input").click());
        assert.equal(window.document.querySelector(".qs-cache-notice"), null);
        assert.equal(state.cacheNoticeID, undefined);
        await React.act(async () => dispatch({ type: "leave" }));
        await render({ ...advice, timestamp: advice.timestamp + 2 });
        assert.equal(state.mode, "rest");
        await React.act(async () => window.document.querySelector("input").click());
        assert.equal(state.mode, "hover");
        await render(advice, { available: false });
        assert.equal(state.cacheNoticeID, undefined);
        assert.equal(window.document.querySelector(".qs-cache-notice"), null);
        await render({ ...advice, timestamp: advice.timestamp - 121 });
        assert.equal(state.cacheNoticeID, undefined);
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    for (const [key, descriptor] of previous) descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key];
    window.close();
  }
});
