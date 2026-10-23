import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

const source = { canonicalHomeKey: "home-a", physicalHomeKey: "physical-a", transitionGeneration: 1 };
const turn = {
  id: "turn-1", sessionId: "session", sessionTitle: "测试会话", turnIndexInSession: 10,
  timestamp: "2026-10-23T03:06:58Z", userPrompt: "问题", assistantResponse: "回答",
  requestCount: 102, lowHitCount: 2, zeroHitCount: 2,
  breakdown: { inputTokens: 9356604, cachedInputTokens: 8683648, outputTokens: 44810, totalTokens: 9401414, calls: 1 },
};
const request = (index) => ({
  id: `request-${index}`, timestamp: "2026-10-23T02:44:38Z", model: "gpt-6.1-sol",
  breakdown: { inputTokens: 318414, cachedInputTokens: index === 0 ? 0 : 310000, outputTokens: 3648, totalTokens: 322062, calls: 1 },
});

async function withDom(run) {
  const dom = new Window({ url: "http://localhost/" });
  const names = ["window", "document", "navigator", "HTMLElement", "Node", "Event", "MouseEvent", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"];
  const old = new Map(names.map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  for (const name of names) Object.defineProperty(globalThis, name, { configurable: true, writable: true, value: name === "IS_REACT_ACT_ENVIRONMENT" ? true : dom.window[name] });
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { CacheTurnRequestsDialog } = await load("/src/components/cacheHitRanking/CacheTurnRequestsDialog.tsx");
      const container = dom.document.createElement("div"); dom.document.body.append(container);
      const root = createRoot(container);
      try { await run({ React, root, container, dom, load, Component: CacheTurnRequestsDialog }); }
      finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    for (const [name, descriptor] of old) descriptor ? Object.defineProperty(globalThis, name, descriptor) : delete globalThis[name];
    dom.close();
  }
}

test("request details display weighted totals and exact usage, paginate on demand, and close with Escape", async () => {
  await withDom(async ({ React, root, container, dom, Component }) => {
    const calls = []; let closed = 0;
    const loadRequests = async (...args) => {
      calls.push(args);
      return args[2] === 0 ? Array.from({ length: 101 }, (_, i) => request(i)) : [request(100), request(101)];
    };
    await React.act(async () => root.render(React.createElement(Component, { turn, sourceToken: source, loadRequests, onClose: () => closed++ })));
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], [source, "turn-1", 0, 101]);
    assert.equal(container.querySelectorAll("tbody tr").length, 100);
    assert.match(container.textContent, /整轮加权 92.81%/);
    assert.match(container.textContent, /低命中 2 次 · 零命中 2 次/);
    assert.match(container.querySelector("tbody tr").textContent, /318,414/);
    assert.match(container.querySelector("tbody tr").textContent, /零命中/);
    assert.equal(container.querySelector("time").dateTime, "2026-10-23T02:44:38Z");
    const more = [...container.querySelectorAll("button")].find((b) => b.textContent === "继续加载");
    await React.act(async () => more.click());
    assert.equal(calls[1][2], 100);
    assert.equal(container.querySelectorAll("tbody tr").length, 102);
    assert.equal([...container.querySelectorAll("button")].some((b) => b.textContent === "继续加载"), false);
    await React.act(async () => dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    assert.equal(closed, 1);
  });
});

test("late request pages from a previous source never appear after a source change", async () => {
  await withDom(async ({ React, root, container, Component }) => {
    let completeOld; const calls = [];
    const loadRequests = (...args) => {
      calls.push(args);
      if (args[0].canonicalHomeKey === "home-a") return new Promise((resolve) => { completeOld = resolve; });
      return Promise.resolve([{ ...request(1), id: "new-row", model: "new-home-model" }]);
    };
    const props = { turn, sourceToken: source, loadRequests, onClose() {} };
    await React.act(async () => root.render(React.createElement(Component, props)));
    await React.act(async () => root.render(React.createElement(Component, { ...props, sourceToken: { ...source, canonicalHomeKey: "home-b", transitionGeneration: 2 } })));
    assert.match(container.textContent, /new-home-model/);
    await React.act(async () => completeOld([{ ...request(0), model: "old-home-model" }]));
    assert.doesNotMatch(container.textContent, /old-home-model/);
    assert.equal(calls.length, 2);
    assert.equal(container.querySelectorAll("tbody tr").length, 1);
  });
});


test("ranking row opens source-scoped request details only after a click", async () => {
  await withDom(async ({ React, root, container, dom, load }) => {
    const calls = [];
    dom.window.__TAURI_INTERNALS__ = { invoke: async (command, args) => {
      calls.push([command, args]);
      return [request(0)];
    } };
    const { CacheHitRanking } = await load("/src/components/CacheHitRanking.tsx");
    await React.act(async () => root.render(React.createElement(CacheHitRanking, {
      cacheUsage: { turns: [turn], sessions: [] }, sourceToken: source,
    })));
    assert.equal(calls.length, 0);
    assert.match(container.textContent, /92.81%/);
    assert.match(container.textContent, /低命中 2 次 · 零命中 2 次/);
    const open = container.querySelector('[aria-label="查看本轮每次请求的时间和用量"]');
    assert.ok(open && !open.disabled);
    await React.act(async () => open.click());
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], ["read_cache_turn_requests", { sourceToken: source, turnId: "turn-1", offset: 0, limit: 101 }]);
    assert.ok(container.querySelector('[role="dialog"][aria-label="本轮请求明细"]'));
    assert.match(container.querySelector("tbody").textContent, /318,414/);
    await React.act(async () => container.querySelector('[aria-label="关闭本轮请求明细"]').click());
    assert.equal(container.querySelector('[role="dialog"]'), null);
  });
});
