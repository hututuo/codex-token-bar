import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("hidden compact quota rejects late data and refreshes once for the next activation", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
      const { useCompactPanelQuota } = await load("/src/surfaces/useCompactPanelQuota.ts");
      const firstRead = deferred();
      let reads = 0;
      const readQuota = () => {
        reads += 1;
        return reads === 1
          ? firstRead.promise
          : Promise.resolve(quotaBundle(emptyAccountQuotaBundle, "fresh"));
      };
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);

      function Probe({ active }) {
        const quota = useCompactPanelQuota({
          active,
          enabled: true,
          initialDelayMs: 0,
          intervalMs: 60_000,
        }, readQuota);
        return React.createElement("output", null, quota.testLabel ?? "initial");
      }
      const render = async (active) => {
        await React.act(async () => root.render(React.createElement(Probe, { active })));
      };

      try {
        await render(false);
        await tick();
        assert.equal(reads, 0);
        assert.equal(container.textContent, "initial");

        await render(true);
        await waitFor(() => reads === 1);
        await render(false);
        await React.act(async () => {
          firstRead.resolve(quotaBundle(emptyAccountQuotaBundle, "late-hidden"));
          await tick();
        });
        assert.equal(container.textContent, "initial");

        await render(true);
        await waitForAct(React, () => reads === 2 && container.textContent === "fresh");
        await render(true);
        await tick();
        assert.equal(reads, 2);
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
