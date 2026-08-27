import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("cache hit ranking keeps ten outer rows, opens detail, and searches with pagination reset", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { CacheHitRanking } = await load("/src/components/CacheHitRanking.tsx");
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);

      try {
        await React.act(async () => root.render(React.createElement(CacheHitRanking, rankingProps())));

        const outer = container.querySelector(".ranking-section");
        assert.ok(outer);
        assert.equal(outer.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 10);
        assert.ok(outer.querySelector(".ranking-check"));
        assert.ok(outer.querySelector('[role="tablist"]'));
        const openButton = outer.querySelector(".cache-ranking-open-button");
        assert.ok(openButton);
        assert.equal(openButton.textContent, "查看完整排行");
        assert.equal(container.querySelector('[role="dialog"]'), null);

        await React.act(async () => openButton.click());
        let dialog = container.querySelector('[role="dialog"][aria-modal="true"]');
        assert.ok(dialog);
        assert.equal(dialog.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 10);
        assert.match(dialog.textContent ?? "", /已显示 10 \/ 共 22/);
        assert.ok(dialog.querySelector('input[type="search"]'));
        assert.ok(dialog.querySelector(".cache-ranking-load-more"));

        await React.act(async () => dialog.querySelector(".cache-ranking-load-more")?.click());
        dialog = container.querySelector('[role="dialog"][aria-modal="true"]');
        assert.ok(dialog);
        assert.equal(dialog.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 20);
        assert.match(dialog.textContent ?? "", /已显示 20 \/ 共 22/);

        const finalLoadButton = dialog.querySelector(".cache-ranking-load-more");
        assert.ok(finalLoadButton);
        assert.equal(finalLoadButton.textContent?.trim(), "继续加载 2 条");
        await React.act(async () => finalLoadButton.click());
        dialog = container.querySelector('[role="dialog"][aria-modal="true"]');
        assert.ok(dialog);
        assert.equal(dialog.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 22);
        assert.match(dialog.textContent ?? "", /已显示 22 \/ 共 22/);
        assert.equal(dialog.querySelector(".cache-ranking-load-more"), null);

        const search = dialog.querySelector('input[type="search"]');
        assert.ok(search);
        await setInput(React.act, search, "会话 2", dom.window);
        dialog = container.querySelector('[role="dialog"][aria-modal="true"]');
        assert.ok(dialog);
        assert.equal(dialog.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 3);
        assert.match(dialog.textContent ?? "", /已显示 3 \/ 共 3/);
        assert.equal(dialog.querySelector(".cache-ranking-load-more"), null);

        await setInput(React.act, search, "", dom.window);
        dialog = container.querySelector('[role="dialog"][aria-modal="true"]');
        assert.ok(dialog);
        assert.equal(dialog.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 10);
        assert.match(dialog.textContent ?? "", /已显示 10 \/ 共 22/);

        const sessionsTab = [...dialog.querySelectorAll('[role="tab"]')].find((tab) => tab.textContent === "会话");
        assert.ok(sessionsTab);
        await React.act(async () => sessionsTab.click());
        dialog = container.querySelector('[role="dialog"][aria-modal="true"]');
        assert.ok(dialog);
        assert.equal(dialog.querySelectorAll(".ranking-row:not(.ranking-row--empty)").length, 10);
        assert.match(dialog.textContent ?? "", /已显示 10 \/ 共 25/);

        const escape = new dom.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          key: "Escape",
        });
        await React.act(async () => dom.window.dispatchEvent(escape));
        assert.equal(container.querySelector('[role="dialog"]'), null);
        assert.equal(dom.document.activeElement, openButton);

        await React.act(async () => openButton.click());
        const layer = container.querySelector(".cache-ranking-detail-layer");
        assert.ok(layer);
        await React.act(async () => layer.dispatchEvent(new dom.MouseEvent("mousedown", {
          bubbles: true,
          cancelable: true,
        })));
        assert.equal(container.querySelector('[role="dialog"]'), null);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    dom.close();
  }
});

function rankingProps() {
  return {
    cacheUsage: {
      sessions: Array.from({ length: 25 }, (_, index) => ({
        id: `session-${index}`,
        title: `会话 ${index}`,
        lastUpdated: `2026-07-${String((index % 9) + 1).padStart(2, "0")}T09:00:00Z`,
        breakdown: {
          inputTokens: 2_000,
          cachedInputTokens: index * 50,
          outputTokens: 0,
          totalTokens: 2_000,
          calls: 2,
        },
      })),
      turns: Array.from({ length: 22 }, (_, index) => ({
        id: `turn-${index}`,
        sessionId: `session-${index}`,
        sessionTitle: `会话 ${index}`,
        timestamp: `2026-07-${String((index % 9) + 1).padStart(2, "0")}T10:00:00Z`,
        turnIndexInSession: 2,
        userPrompt: `问题 ${index}`,
        assistantResponse: `回答 ${index}`,
        breakdown: {
          inputTokens: 2_000,
          cachedInputTokens: index * 50,
          outputTokens: 0,
          totalTokens: 2_000,
          calls: 1,
        },
      })),
    },
    legacyItems: [],
  };
}

async function setInput(act, input, value, window) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set;
  assert.ok(setter);
  setter.call(input, value);
  await act(async () => input.dispatchEvent(new window.Event("input", { bubbles: true, cancelable: true })));
}

function installDomGlobals(dom) {
  const previous = new Map();
  for (const [key, value] of Object.entries({
    window: dom,
    document: dom.document,
    navigator: dom.navigator,
    HTMLElement: dom.HTMLElement,
    Event: dom.Event,
    KeyboardEvent: dom.KeyboardEvent,
  })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, value, writable: true });
  }
  return () => {
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  };
}
