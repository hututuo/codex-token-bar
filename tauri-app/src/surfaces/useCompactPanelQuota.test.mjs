import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

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
        }, readQuota);
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
        await waitForAct(React, () => reads === 4 && container.textContent === "initial");
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
