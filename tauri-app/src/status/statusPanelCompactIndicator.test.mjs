import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("the whole compact indicator opens the summary by click Enter and Space", async () => {
  const dom = new Window({ url: "http://localhost/?surface=status" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { StatusPanelCompactIndicator } = await load(
        "/src/status/StatusPanelCompactIndicator.tsx",
      );
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let expansions = 0;

      try {
        await React.act(async () => root.render(
          React.createElement(StatusPanelCompactIndicator, {
            columns: [
              {
                top: { text: "0.0" },
                bottom: { secondary: true, text: "tok/s" },
              },
              {
                top: { text: "5 —" },
                bottom: { text: "7 76%" },
              },
              {
                top: { text: "1 Sol·MAX" },
                bottom: { text: "2 Luna·H" },
              },
            ],
            onExpand: () => {
              expansions += 1;
            },
            tooltip: "实时速度 0.0/s · 5 小时 —",
          }),
        ));

        const indicator = container.querySelector('[role="button"]');
        assert.ok(indicator);
        assert.equal(indicator.getAttribute("tabindex"), "0");
        assert.equal(indicator.getAttribute("aria-label"), "实时速度 0.0/s · 5 小时 —");
        assert.equal(indicator.querySelector(".status-indicator-compact-columns")?.getAttribute("aria-hidden"), "true");
        assert.equal(indicator.textContent, "0.0tok/s5 —7 76%1 Sol·MAX2 Luna·H");
        assert.deepEqual(
          [...indicator.querySelectorAll(".status-indicator-column")].map((node) => node.textContent),
          ["0.0tok/s", "5 —7 76%", "1 Sol·MAX2 Luna·H"],
        );
        assert.equal(indicator.querySelector(".is-secondary")?.textContent, "tok/s");
        assert.equal(container.textContent.includes("5 小时"), false);

        await React.act(async () => indicator.click());
        assert.equal(expansions, 1);

        const enter = new dom.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          key: "Enter",
        });
        await React.act(async () => indicator.dispatchEvent(enter));
        assert.equal(enter.defaultPrevented, true);
        assert.equal(expansions, 2);

        const space = new dom.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          key: " ",
        });
        await React.act(async () => indicator.dispatchEvent(space));
        assert.equal(space.defaultPrevented, true);
        assert.equal(expansions, 3);

        const escape = new dom.KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          key: "Escape",
        });
        await React.act(async () => indicator.dispatchEvent(escape));
        assert.equal(escape.defaultPrevented, false);
        assert.equal(expansions, 3);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    restoreGlobals();
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    dom.close();
  }
});

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
