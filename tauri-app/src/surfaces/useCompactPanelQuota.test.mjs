import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("production compact surfaces follow dashboard quota events without issuing their own reads", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
      const { useCompactPanelQuota } = await load("/src/surfaces/useCompactPanelQuota.ts");
      let quotaHandler = null;
      let resetHandler = null;
      let quotaReads = 0;
      let resetReads = 0;
      const subscriptions = {
        onQuota: async (handler) => {
          quotaHandler = handler;
          return () => { quotaHandler = null; };
        },
        onResetCredits: async (handler) => {
          resetHandler = handler;
          return () => { resetHandler = null; };
        },
      };
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const source = sourceToken("event-source", 3);

      function Probe() {
        const quota = useCompactPanelQuota({
          active: true,
          enabled: true,
          followDashboardUpdates: true,
          initialDelayMs: 0,
          intervalMs: 1_000,
          sourceToken: source,
        }, () => {
          quotaReads += 1;
          return Promise.resolve(null);
        }, () => {
          resetReads += 1;
          return Promise.resolve(null);
        }, subscriptions);
        return React.createElement(
          "output",
          null,
          `${quota.testLabel ?? "initial"}|${quota.quota.resetCredit.status}`,
        );
      }

      try {
        await React.act(async () => {
          root.render(React.createElement(Probe));
          await tick();
        });
        assert.equal(typeof quotaHandler, "function");
        assert.equal(typeof resetHandler, "function");
        assert.equal(quotaReads, 0);
        assert.equal(resetReads, 0);

        await React.act(async () => {
          quotaHandler({
            quota: quotaBundle(emptyAccountQuotaBundle, "wrong-source"),
            sourceToken: sourceToken("other-source", 4),
          });
          quotaHandler({
            quota: quotaBundle(emptyAccountQuotaBundle, "dashboard-quota"),
            sourceToken: source,
          });
          resetHandler({ resetCredits: resetCreditBundle(), sourceToken: source });
          await tick();
        });

        assert.equal(container.textContent, "dashboard-quota|重置卡已更新");
        assert.equal(quotaReads, 0);
        assert.equal(resetReads, 0);
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

test("hidden compact quota rejects late data and refreshes once for the next activation", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const intervals = new Map();
  let nextIntervalId = 1;
  window.setInterval = (callback, delayMs) => {
    const id = nextIntervalId;
    nextIntervalId += 1;
    intervals.set(id, { callback, delayMs });
    return id;
  };
  window.clearInterval = (id) => intervals.delete(id);

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
      const { useCompactPanelQuota } = await load("/src/surfaces/useCompactPanelQuota.ts");
      const delayedARead = deferred();
      const readTokens = [];
      let reads = 0;
      const readQuota = (_forceRefresh, sourceToken) => {
        readTokens.push(sourceToken);
        reads += 1;
        if (reads === 1) {
          return Promise.resolve(quotaBundle(emptyAccountQuotaBundle, "source-a"));
        }
        if (reads === 2) {
          return delayedARead.promise;
        }
        if (reads === 4) {
          return Promise.resolve(null);
        }
        return Promise.resolve(quotaBundle(emptyAccountQuotaBundle, "source-b"));
      };
      const readResetCredits = () => Promise.resolve(resetCreditBundle());
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);

      function Probe({ active, sourceToken }) {
        const quota = useCompactPanelQuota({
          active,
          enabled: true,
          initialDelayMs: 0,
          intervalMs: 60_000,
          sourceToken,
        }, readQuota, readResetCredits);
        return React.createElement("output", null, quota.testLabel ?? "initial");
      }
      const render = async (active, sourceToken) => {
        await React.act(async () => root.render(React.createElement(Probe, { active, sourceToken })));
      };
      const sourceA = sourceToken("physical-a", 1);
      const sourceB = sourceToken("physical-b", 2);

      try {
        await render(false, sourceA);
        await tick();
        assert.equal(reads, 0);
        assert.equal(container.textContent, "initial");

        await render(true, sourceA);
        await waitForAct(React, () => reads === 1 && container.textContent === "source-a");
        assert.equal(readTokens[0].physicalHomeKey, "physical-a");
        const quotaInterval = [...intervals.values()].find(({ delayMs }) => delayMs === 60_000);
        assert.ok(quotaInterval);
        await React.act(async () => {
          quotaInterval.callback();
          await tick();
        });
        assert.equal(reads, 2);
        assert.equal(readTokens[1].physicalHomeKey, "physical-a");

        await render(false, sourceA);
        assert.equal(container.textContent, "source-a");
        await render(false, sourceB);
        assert.equal(container.textContent, "initial");
        await React.act(async () => {
          delayedARead.resolve(quotaBundle(emptyAccountQuotaBundle, "late-source-a"));
          await tick();
        });
        assert.equal(container.textContent, "initial");

        await render(true, sourceB);
        await waitForAct(React, () => reads === 3 && container.textContent === "source-b");
        assert.equal(readTokens[2].physicalHomeKey, "physical-b");
        await render(true, sourceB);
        await tick();
        assert.equal(reads, 3);

        const sourceBInterval = [...intervals.values()].find(({ delayMs }) => delayMs === 60_000);
        assert.ok(sourceBInterval);
        await React.act(async () => {
          sourceBInterval.callback();
          await tick();
        });
        await waitForAct(React, () => reads === 4);
        assert.equal(container.textContent, "source-b");
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

test("compact quota and reset channels retry independently and never schedule past one minute", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const timeouts = new Map();
  const intervals = new Map();
  let nextTimerId = 1;
  window.setTimeout = (callback, delayMs) => {
    const id = nextTimerId;
    nextTimerId += 1;
    timeouts.set(id, { callback, delayMs });
    return id;
  };
  window.clearTimeout = (id) => timeouts.delete(id);
  window.setInterval = (callback, delayMs) => {
    const id = nextTimerId;
    nextTimerId += 1;
    intervals.set(id, { callback, delayMs });
    return id;
  };
  window.clearInterval = (id) => intervals.delete(id);

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
      const { useCompactPanelQuota } = await load("/src/surfaces/useCompactPanelQuota.ts");
      let quotaReads = 0;
      let resetReads = 0;
      const readQuota = () => {
        quotaReads += 1;
        return Promise.resolve(quotaReads < 3
          ? null
          : quotaBundle(emptyAccountQuotaBundle, "quota-recovered"));
      };
      const readResetCredits = () => {
        resetReads += 1;
        return Promise.resolve(resetReads < 2 ? null : resetCreditBundle());
      };
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const retrySource = sourceToken("physical-retry", 1);

      function Probe() {
        const quota = useCompactPanelQuota({
          active: true,
          enabled: true,
          initialDelayMs: 0,
          intervalMs: 600_000,
          sourceToken: retrySource,
        }, readQuota, readResetCredits);
        return React.createElement(
          "output",
          null,
          `${quota.testLabel ?? "initial"}|${quota.quota.resetCredit.status}`,
        );
      }

      const fireTimeoutsAt = async (delayMs) => {
        const pending = [...timeouts.entries()].filter(([, timer]) => timer.delayMs === delayMs);
        for (const [id] of pending) timeouts.delete(id);
        await React.act(async () => {
          for (const [, timer] of pending) timer.callback();
          await tick();
          await tick();
        });
      };

      try {
        await React.act(async () => root.render(React.createElement(Probe)));
        assert.equal([...intervals.values()].some((timer) => timer.delayMs === 60_000), true);
        assert.equal([...intervals.values()].some((timer) => timer.delayMs > 60_000), false);

        await fireTimeoutsAt(0);
        assert.equal(quotaReads, 1);
        assert.equal(resetReads, 1);
        assert.equal([...timeouts.values()].filter((timer) => timer.delayMs === 1_000).length, 2);

        await fireTimeoutsAt(1_000);
        assert.equal(quotaReads, 2);
        assert.equal(resetReads, 2);
        assert.match(container.textContent, /重置卡已更新/);
        assert.equal([...timeouts.values()].filter((timer) => timer.delayMs === 2_000).length, 1);

        await fireTimeoutsAt(2_000);
        assert.equal(quotaReads, 3);
        assert.equal(resetReads, 2);
        assert.match(container.textContent, /quota-recovered\|重置卡已更新/);
        assert.equal(
          [...timeouts.values()].some((timer) => timer.delayMs > 60_000),
          false,
        );
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

test("source transition cancels old-channel retry timers before they can read the new state", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const timeouts = new Map();
  let nextTimerId = 1;
  window.setTimeout = (callback, delayMs) => {
    const id = nextTimerId;
    nextTimerId += 1;
    timeouts.set(id, { callback, delayMs });
    return id;
  };
  window.clearTimeout = (id) => timeouts.delete(id);
  window.setInterval = () => nextTimerId++;
  window.clearInterval = () => {};

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
      const { useCompactPanelQuota } = await load("/src/surfaces/useCompactPanelQuota.ts");
      const readTokens = [];
      const readQuota = (_forceRefresh, token) => {
        readTokens.push(token.physicalHomeKey);
        return Promise.resolve(token.physicalHomeKey === "source-a"
          ? null
          : quotaBundle(emptyAccountQuotaBundle, "source-b-data"));
      };
      const readResetCredits = () => Promise.resolve(resetCreditBundle());
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const sourceA = sourceToken("source-a", 1);
      const sourceB = sourceToken("source-b", 2);

      function Probe({ source }) {
        const quota = useCompactPanelQuota({
          active: true,
          enabled: true,
          initialDelayMs: 0,
          intervalMs: 60_000,
          sourceToken: source,
        }, readQuota, readResetCredits);
        return React.createElement("output", null, quota.testLabel ?? "initial");
      }

      const fireAt = async (delayMs) => {
        const pending = [...timeouts.entries()].filter(([, timer]) => timer.delayMs === delayMs);
        for (const [id] of pending) timeouts.delete(id);
        await React.act(async () => {
          for (const [, timer] of pending) timer.callback();
          await tick();
          await tick();
        });
      };

      try {
        await React.act(async () => root.render(React.createElement(Probe, { source: sourceA })));
        await fireAt(0);
        assert.deepEqual(readTokens, ["source-a"]);
        assert.equal([...timeouts.values()].some((timer) => timer.delayMs === 1_000), true);

        await React.act(async () => root.render(React.createElement(Probe, { source: sourceB })));
        assert.equal([...timeouts.values()].some((timer) => timer.delayMs === 1_000), false);
        await fireAt(0);

        assert.deepEqual(readTokens, ["source-a", "source-b"]);
        assert.equal(container.textContent, "source-b-data");
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

function deferred() {
  let resolve;
  const promise = new Promise((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

function quotaBundle(emptyAccountQuotaBundle, testLabel) {
  return { ...emptyAccountQuotaBundle(), testLabel };
}

function resetCreditBundle() {
  return {
    updatedAt: "2026-08-11T00:00:00Z",
    resetCredit: { availableCount: 0, status: "重置卡已更新", credits: [] },
    warnings: [],
    diagnostics: [],
    successful: true,
  };
}

function sourceToken(physicalHomeKey, transitionGeneration) {
  return {
    canonicalHomeKey: "/same/.codex",
    physicalHomeKey,
    transitionGeneration,
  };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) {
      return;
    }
    await tick();
  }
  assert.fail("condition did not become true");
}

async function waitForAct(React, predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) {
      return;
    }
    await React.act(async () => {
      await tick();
    });
  }
  assert.fail("condition did not become true");
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
