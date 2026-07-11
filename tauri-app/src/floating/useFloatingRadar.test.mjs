import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("floating Radar pauses hidden, refreshes once on show, and retains its last snapshot", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const intervals = new Map();
  let nextIntervalId = 1;
  window.setInterval = (callback) => {
    const id = nextIntervalId;
    nextIntervalId += 1;
    intervals.set(id, callback);
    return id;
  };
  window.clearInterval = (id) => intervals.delete(id);

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useFloatingRadar } = await load("/src/floating/useFloatingRadar.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      let reads = 0;
      const readRadar = async () => {
        reads += 1;
        return { snapshot: { testLabel: `radar-${reads}` } };
      };
      function Probe({ active }) {
        const snapshot = useFloatingRadar(active, readRadar);
        return React.createElement("output", null, snapshot?.testLabel ?? "none");
      }
      const render = async (active) => {
        await React.act(async () => root.render(React.createElement(Probe, { active })));
      };

      try {
        await render(false);
        assert.equal(reads, 0);
        assert.equal(intervals.size, 0);
        assert.equal(container.textContent, "none");

        await render(true);
        await waitFor(() => container.textContent === "radar-1");
        assert.equal(reads, 1);
        assert.equal(intervals.size, 1);

        await render(true);
        assert.equal(reads, 1);
        assert.equal(intervals.size, 1);

        await render(false);
        assert.equal(intervals.size, 0);
        assert.equal(container.textContent, "radar-1");

        await render(true);
        await waitFor(() => container.textContent === "radar-2");
        assert.equal(reads, 2);
        assert.equal(intervals.size, 1);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

function installDomGlobals(window) {
  const values = {
    document: window.document,
    window,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    Event: window.Event,
    MutationObserver: window.MutationObserver,
  };
  const previous = new Map();
  for (const [name, value] of Object.entries(values)) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
  }
  return () => {
    for (const [name, descriptor] of previous) {
      if (descriptor) {
        Object.defineProperty(globalThis, name, descriptor);
      } else {
        delete globalThis[name];
      }
    }
  };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.fail("condition did not become true");
}
