import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("status lifecycle dismisses outside blur or Escape and becomes active after the next focused show", async () => {
  const dom = new Window({ url: "http://localhost/?surface=status" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useStatusPanelWindowLifecycle } = await load("/src/status/useStatusPanelWindowLifecycle.ts");
      let visible = true;
      let focused = true;
      let blurDismissals = 0;
      const dependencies = {
        dismissOnBlur() {
          blurDismissals += 1;
          visible = false;
          return Promise.resolve(false);
        },
        hasFocus: () => focused,
        isVisible: () => Promise.resolve(visible),
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);

      function Probe() {
        const active = useStatusPanelWindowLifecycle(dependencies);
        return React.createElement("output", null, String(active));
      }

      try {
        await React.act(async () => root.render(React.createElement(Probe)));
        await waitForAct(React, () => container.textContent === "true");

        focused = false;
        await React.act(async () => dom.dispatchEvent(new dom.Event("blur")));
        assert.equal(container.textContent, "false");
        assert.equal(blurDismissals, 1, "ordinary outside blur crosses the blur-dismiss seam");

        visible = true;
        focused = true;
        await React.act(async () => dom.dispatchEvent(new dom.Event("focus")));
        await waitForAct(React, () => container.textContent === "true");
        assert.equal(container.textContent, "true", "a tray show followed by focus reactivates StatusPanelApp");

        const escape = new dom.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Escape" });
        await React.act(async () => dom.dispatchEvent(escape));
        assert.equal(escape.defaultPrevented, true);
        assert.equal(container.textContent, "false");
        assert.equal(blurDismissals, 2, "Escape crosses the same native dismiss seam");
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

async function waitForAct(React, predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await React.act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  assert.fail("condition was not reached");
}
