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
      let staleMarks = 0;
      let failureMarks = 0;
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
          onPreciseDashboardFailure() {
            failureMarks += 1;
          },
          onPreciseDashboardStale() {
            staleMarks += 1;
          },
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
        assert.equal(staleMarks, 1, "a failed optional precise read must leave freshness false");
        assert.equal(failureMarks, 1, "the settled failure must persist one continuity gap");
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

test("periodic precise loads probe the source before reusing cache and fail safe", async () => {
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
        canonicalHomeKey: "canonical-periodic-home",
        physicalHomeKey: "physical-periodic-home",
        transitionGeneration: 1,
      };
      let preciseReads = 0;
      let probeState = "unchanged";
      let probeGenerationOverride = null;
      const source = {
        async readUsageCacheStatus() {
          return {};
        },
        async readPreciseDashboardSourceProbe() {
          if (probeState === "reject") {
            throw new Error("probe unavailable");
          }
          return {
            state: probeState,
            publishedGeneration: probeGenerationOverride ?? String(preciseReads),
          };
        },
        async readPreciseDashboardSnapshot() {
          preciseReads += 1;
          return {
            revision: preciseReads,
            preciseRecentUsageFresh: true,
            preciseRecentUsageCoveredAt: "2026-08-06T00:00:00.000Z",
            preciseAttributionGeneration: preciseReads,
          };
        },
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);

      function Probe({ generation, force }) {
        usePreciseDashboardLoad({
          active: true,
          dashboardReady: true,
          generation,
          loading: false,
          forcePreciseRefresh: force,
          source,
          sourceToken,
          onPreciseDashboard() {},
        });
        return null;
      }

      const runGeneration = async (generation, force) => {
        await React.act(async () => root.render(React.createElement(Probe, { generation, force })));
        assert.equal(timers.pendingCount(), 1);
        await React.act(async () => {
          timers.runNext();
          await Promise.resolve();
          await Promise.resolve();
          await Promise.resolve();
        });
      };

      try {
        await runGeneration(1, true);
        assert.equal(preciseReads, 1, "the forced baseline should create one precise owner");

        await runGeneration(2, false);
        assert.equal(preciseReads, 1, "an unchanged probe should reuse the last-good snapshot");

        probeGenerationOverride = "99";
        await runGeneration(3, false);
        assert.equal(preciseReads, 2, "an advanced generation must not reuse the old snapshot");

        probeGenerationOverride = null;
        probeState = "changed";
        await runGeneration(4, false);
        assert.equal(preciseReads, 3, "an append/changed probe must enter precise refresh");

        probeState = "unknown";
        await runGeneration(5, false);
        assert.equal(preciseReads, 4, "an unknown probe must fail safe to precise refresh");

        probeState = "reject";
        await runGeneration(6, false);
        assert.equal(preciseReads, 5, "a probe failure must fail safe to precise refresh");
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

test("a cadence tick joins an in-flight owner without probing or scheduling a trailing run", async () => {
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
        canonicalHomeKey: "canonical-in-flight-home",
        physicalHomeKey: "physical-in-flight-home",
        transitionGeneration: 1,
      };
      const owner = deferred();
      let preciseReads = 0;
      let probeReads = 0;
      const source = {
        async readUsageCacheStatus() {
          return {};
        },
        async readPreciseDashboardSourceProbe() {
          probeReads += 1;
          return { state: "changed", publishedGeneration: "late" };
        },
        readPreciseDashboardSnapshot() {
          preciseReads += 1;
          if (preciseReads === 1) {
            return owner.promise;
          }
          return Promise.resolve({
            revision: preciseReads,
            preciseRecentUsageFresh: true,
            preciseRecentUsageCoveredAt: "2026-08-06T00:00:00.000Z",
            preciseAttributionGeneration: preciseReads,
          });
        },
      };
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);

      function Probe({ generation, force }) {
        usePreciseDashboardLoad({
          active: true,
          dashboardReady: true,
          generation,
          loading: false,
          forcePreciseRefresh: force,
          source,
          sourceToken,
          onPreciseDashboard() {},
        });
        return null;
      }

      const runTimer = async (generation, force) => {
        await React.act(async () => root.render(React.createElement(Probe, { generation, force })));
        assert.equal(timers.pendingCount(), 1);
        await React.act(async () => {
          timers.runNext();
          await Promise.resolve();
          await Promise.resolve();
          await Promise.resolve();
        });
      };

      try {
        await runTimer(1, true);
        assert.equal(preciseReads, 1);

        // The owner is still pending. The cadence generation joins it after
        // status, but must not call the source probe or ask for a trailing run.
        await runTimer(2, false);
        assert.equal(probeReads, 0);
        assert.equal(preciseReads, 1);

        owner.resolve({
          revision: 1,
          preciseRecentUsageFresh: true,
          preciseRecentUsageCoveredAt: "2026-08-06T00:00:00.000Z",
          preciseAttributionGeneration: 1,
        });
        await React.act(async () => {
          await Promise.resolve();
          await Promise.resolve();
          await Promise.resolve();
        });
        assert.equal(preciseReads, 1);

        // Once the owner has settled, the next cadence is allowed to probe;
        // the changed result then starts one fresh precise owner.
        await runTimer(3, false);
        assert.equal(probeReads, 1);
        assert.equal(preciseReads, 2);
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

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
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
