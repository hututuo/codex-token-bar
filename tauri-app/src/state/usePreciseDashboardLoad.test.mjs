import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("a render during the cold-start grace period cannot permanently skip the precise scan", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(dom);
  const timers = installManualWindowTimers(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { usePreciseDashboardLoad } = await load("/src/state/usePreciseDashboardLoad.ts");
      const sourceToken = {
        canonicalHomeKey: "canonical-home",
        physicalHomeKey: "physical-home",
        transitionGeneration: 1,
      };
      let preciseReads = 0;
      const source = {
        async readUsageCacheStatus() {
          return {};
        },
        async readPreciseDashboardSnapshot() {
          preciseReads += 1;
          return null;
        },
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);

      function Probe({ renderRevision }) {
        usePreciseDashboardLoad({
          active: true,
          dashboardReady: true,
          generation: 1,
          loading: false,
          source,
          sourceToken,
          onPreciseDashboard() {},
          onUsageCacheStatus() {
            void renderRevision;
          },
        });
        return null;
      }

      try {
        await React.act(async () => root.render(React.createElement(Probe, { renderRevision: 1 })));
        assert.equal(timers.pendingCount(), 1);

        // A normal callback-identity change tears down the first effect before its
        // 1.5 second timer fires. The replacement effect must still own a timer.
        await React.act(async () => root.render(React.createElement(Probe, { renderRevision: 2 })));
        assert.equal(timers.pendingCount(), 1);

        await React.act(async () => {
          timers.runNext();
          await Promise.resolve();
          await Promise.resolve();
        });
        assert.equal(preciseReads, 1);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    timers.restore();
    restoreGlobals();
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    dom.close();
  }
});

function installManualWindowTimers(dom) {
  const originalSetTimeout = dom.setTimeout.bind(dom);
  const originalClearTimeout = dom.clearTimeout.bind(dom);
  const pending = new Map();
  let sequence = 0;
  dom.setTimeout = (callback) => {
    sequence += 1;
    pending.set(sequence, callback);
    return sequence;
  };
  dom.clearTimeout = (timer) => {
    pending.delete(Number(timer));
  };
  return {
    pendingCount: () => pending.size,
    runNext() {
      const next = pending.entries().next().value;
      assert.ok(next, "expected a pending startup timer");
      const [id, callback] = next;
      pending.delete(id);
      callback();
    },
    restore() {
      dom.setTimeout = originalSetTimeout;
      dom.clearTimeout = originalClearTimeout;
    },
  };
}

function installDomGlobals(dom) {
  const previous = new Map();
  for (const [key, value] of Object.entries({
    window: dom,
    document: dom.document,
    navigator: dom.navigator,
    HTMLElement: dom.HTMLElement,
    Event: dom.Event,
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
