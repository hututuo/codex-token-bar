import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("status lifecycle follows visibility when background ownership is disabled", async () => {
  const dom = new Window({ url: "http://localhost/?surface=status" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useStatusPanelWindowLifecycle } = await load("/src/status/useStatusPanelWindowLifecycle.ts");
      let visible = true;
      let blurDismissals = 0;
      const dependencies = {
        dismissOnBlur() {
          blurDismissals += 1;
          visible = false;
          return Promise.resolve(false);
        },
        isVisible: () => Promise.resolve(visible),
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);

      function Probe() {
        const active = useStatusPanelWindowLifecycle(false, dependencies);
        return React.createElement("output", null, String(active));
      }

      try {
        await React.act(async () => root.render(React.createElement(Probe)));
        await waitForAct(React, () => container.textContent === "true");

        await React.act(async () => dom.dispatchEvent(new dom.Event("blur")));
        assert.equal(container.textContent, "false");
        assert.equal(blurDismissals, 1, "ordinary outside blur crosses the blur-dismiss seam");

        visible = true;
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

test("status lifecycle stays active as a hidden composite readout owner", async () => {
  const dom = new Window({ url: "http://localhost/?surface=status" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useStatusPanelWindowLifecycle } = await load("/src/status/useStatusPanelWindowLifecycle.ts");
      const dependencies = {
        dismissOnBlur: () => Promise.resolve(false),
        isVisible: () => Promise.resolve(false),
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      function Probe() {
        return React.createElement(
          "output",
          null,
          String(useStatusPanelWindowLifecycle(true, dependencies)),
        );
      }
      try {
        await React.act(async () => root.render(React.createElement(Probe)));
        await waitForAct(React, () => container.textContent === "true");
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

test("status lifecycle state exposes visibility separately from background ownership", async () => {
  const dom = new Window({ url: "http://localhost/?surface=status" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useStatusPanelWindowLifecycleState } = await load(
        "/src/status/useStatusPanelWindowLifecycle.ts",
      );
      const dependencies = {
        dismissOnBlur: () => Promise.resolve(false),
        isVisible: () => Promise.resolve(false),
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      function Probe() {
        const state = useStatusPanelWindowLifecycleState(true, dependencies);
        return React.createElement(
          "output",
          null,
          JSON.stringify(state),
        );
      }
      try {
        await React.act(async () => root.render(React.createElement(Probe)));
        await waitForAct(
          React,
          () => container.textContent === '{"active":true,"visible":false}',
        );
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

test("compact status markup has no product-name fallback or redundant close button", async () => {
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(new URL("./StatusPanelApp.tsx", import.meta.url), "utf8");
  const compactMarkup = await readFile(
    new URL("./StatusPanelCompactIndicator.tsx", import.meta.url),
    "utf8",
  );
  const styles = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");

  assert.equal(source.includes("<StatusPanelCompactIndicator"), true);
  assert.equal(compactMarkup.includes("<strong>Codex Token Bar</strong>"), false);
  assert.equal(compactMarkup.includes('aria-label="关闭状态栏详情"'), false);
  assert.equal(compactMarkup.includes("onClick={onExpand}"), true);
  assert.equal(compactMarkup.includes("onKeyDown={handleKeyDown}"), true);
  assert.equal(compactMarkup.includes('role="button"'), true);
  assert.equal(source.includes("desktopPlatform.showStatusPanelWindow()"), true);
  assert.equal(styles.includes(".status-panel-card--compact > button"), false);
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
