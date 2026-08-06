import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("fast and precise dashboard clients invoke production IPC with the exact source token", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ args, command });
          return Promise.resolve(
            command === "read_precise_dashboard_snapshot"
              || command === "read_precise_dashboard_source_probe"
              ? null
              : { stats: {} },
          );
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const {
        readDashboardSnapshot,
        readPreciseDashboardSnapshot,
        readPreciseDashboardSourceProbe,
      } = await load("/src/api/dashboardClient.ts");
      const sourceToken = {
        canonicalHomeKey: "/same/.codex",
        physicalHomeKey: "unix:1:2",
        transitionGeneration: 7,
      };

      await readDashboardSnapshot(sourceToken);
      assert.equal(await readPreciseDashboardSnapshot(sourceToken), null);
      assert.equal(await readPreciseDashboardSourceProbe(sourceToken), null);
      assert.deepEqual(calls, [
        { command: "read_dashboard_snapshot", args: { sourceToken } },
        { command: "read_precise_dashboard_snapshot", args: { sourceToken } },
        { command: "read_precise_dashboard_source_probe", args: { sourceToken } },
      ]);
    });
  } finally {
    if (previousWindow) {
      Object.defineProperty(globalThis, "window", previousWindow);
    } else {
      delete globalThis.window;
    }
  }
});

test("precise dashboard client forwards a bounded refresh reason without source details", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ command, args });
          return Promise.resolve(null);
        },
      },
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const { readPreciseDashboardSnapshot } = await load("/src/api/dashboardClient.ts");
      const sourceToken = {
        canonicalHomeKey: "/private/source",
        physicalHomeKey: "unix:1:2",
        transitionGeneration: 8,
      };
      await readPreciseDashboardSnapshot(sourceToken, "catch-up");
      assert.deepEqual(calls, [{
        command: "read_precise_dashboard_snapshot",
        args: { sourceToken, requestReason: "catch-up" },
      }]);
      assert.equal(calls[0].args.requestReason, "catch-up");
    });
  } finally {
    if (previousWindow) {
      Object.defineProperty(globalThis, "window", previousWindow);
    } else {
      delete globalThis.window;
    }
  }
});

test("mounted main forwards exact tokens and never publishes a delayed snapshot from source A", async () => {
  await withMountedDashboard(async ({ React, container, load, render }) => {
    const { emptyDashboardSnapshot, fallbackPlatformCapabilities } = await load("/src/api/fallback.ts");
    const { INITIAL_PRECISE_DASHBOARD_DELAY_MS } = await load(
      "/src/state/preciseDashboardSchedule.ts",
    );
    const sourceA = sourceEnvelope("physical-a", 1);
    const sourceB = sourceEnvelope("physical-b", 2);
    const delayedA = deferred();
    const fastTokens = [];
    const preciseTokens = [];
    let listener = null;
    const source = dashboardSource({
      emptyDashboardSnapshot,
      fallbackPlatformCapabilities,
      getCodexHome: () => Promise.resolve(sourceA),
      readDashboardSnapshot(token) {
        fastTokens.push(token);
        return token.physicalHomeKey === "physical-a"
          ? delayedA.promise
          : Promise.resolve(snapshot(emptyDashboardSnapshot, "source-b"));
      },
      readPreciseDashboardSnapshot(token) {
        preciseTokens.push(token);
        return Promise.resolve(snapshot(emptyDashboardSnapshot, `precise-${token.physicalHomeKey}`));
      },
    });

    await render(source, {
      subscribeToSourceChanges(handler) {
        listener = handler;
        return Promise.resolve({ ok: true, unlisten: () => {} });
      },
    });
    await waitForAct(React, () => listener !== null && fastTokens.length === 1);
    assert.equal(fastTokens[0].physicalHomeKey, "physical-a");

    await React.act(async () => listener(sourceB));
    await waitForAct(React, () => (
      fastTokens.length === 2
      && JSON.parse(container.textContent).physical === "physical-b"
    ));
    assert.equal(fastTokens[1].physicalHomeKey, "physical-b");

    await React.act(async () => {
      delayedA.resolve(snapshot(emptyDashboardSnapshot, "late-source-a"));
      await tick();
    });
    assert.notEqual(JSON.parse(container.textContent).generatedAt, "late-source-a");
    await React.act(async () => {
      await new Promise((resolve) => setTimeout(
        resolve,
        INITIAL_PRECISE_DASHBOARD_DELAY_MS + 50,
      ));
    });
    await waitForAct(React, () => preciseTokens.length > 0);
    assert.equal(preciseTokens.at(-1).physicalHomeKey, "physical-b");
  });
});

test("main listener failure reconciles slowly and focus advances to B while a healthy listener never polls", async () => {
  await withMountedDashboard(async ({ React, container, load, render, window }) => {
    const { emptyDashboardSnapshot, fallbackPlatformCapabilities } = await load("/src/api/fallback.ts");
    const sourceA = sourceEnvelope("physical-a", 1);
    const sourceB = sourceEnvelope("physical-b", 2);
    let current = sourceA;
    let scheduled = null;
    let cancelled = 0;
    let reads = 0;
    const source = dashboardSource({
      emptyDashboardSnapshot,
      fallbackPlatformCapabilities,
      getCodexHome() {
        reads += 1;
        return Promise.resolve(current);
      },
      readDashboardSnapshot: (token) => Promise.resolve(snapshot(emptyDashboardSnapshot, token.physicalHomeKey)),
    });

    const root = await render(source, {
      subscribeToSourceChanges: () => Promise.resolve({ ok: false, error: "denied" }),
      scheduleSourceReconcile(refresh, intervalMs) {
        scheduled = { refresh, intervalMs };
        return () => {
          cancelled += 1;
          scheduled = null;
        };
      },
    });
    await waitForAct(React, () => scheduled !== null && JSON.parse(container.textContent).physical === "physical-a");
    assert.equal(scheduled.intervalMs, 30_000);
    current = sourceB;
    await React.act(async () => scheduled.refresh());
    await waitForAct(React, () => JSON.parse(container.textContent).physical === "physical-b");

    current = sourceEnvelope("physical-c", 3);
    await React.act(async () => window.dispatchEvent(new window.Event("focus")));
    await waitForAct(React, () => JSON.parse(container.textContent).physical === "physical-c");
    assert.ok(reads >= 3);
    await React.act(async () => root.unmount());
    assert.equal(cancelled, 1);

    let healthySchedules = 0;
    await render(source, {
      subscribeToSourceChanges: () => Promise.resolve({ ok: true, unlisten: () => {} }),
      scheduleSourceReconcile() {
        healthySchedules += 1;
        return () => {};
      },
    });
    await React.act(tick);
    assert.equal(healthySchedules, 0);
  });
});

test("StrictMode cleanup invalidates late authoritative reads and subscription rejection is contained", async () => {
  await withMountedDashboard(async ({ React, load, render, window }) => {
    const { emptyDashboardSnapshot, fallbackPlatformCapabilities } = await load("/src/api/fallback.ts");
    const late = deferred();
    const fastTokens = [];
    let sourceReads = 0;
    let scheduled = 0;
    const source = dashboardSource({
      emptyDashboardSnapshot,
      fallbackPlatformCapabilities,
      getCodexHome() {
        sourceReads += 1;
        return sourceReads <= 2
          ? Promise.resolve(sourceEnvelope("physical-a", 1))
          : late.promise;
      },
      readDashboardSnapshot(token) {
        fastTokens.push(token);
        return Promise.resolve(snapshot(emptyDashboardSnapshot, token.physicalHomeKey));
      },
    });
    const root = await render(source, {
      strict: true,
      subscribeToSourceChanges: () => Promise.reject(new Error("listen rejected")),
      scheduleSourceReconcile() {
        scheduled += 1;
        return () => {};
      },
    });
    await waitForAct(React, () => scheduled > 0 && fastTokens.length > 0);
    await React.act(async () => window.dispatchEvent(new window.Event("focus")));
    await waitForAct(React, () => sourceReads >= 3);
    await React.act(async () => root.unmount());
    await React.act(async () => {
      late.resolve(sourceEnvelope("physical-b", 2));
      await tick();
    });
    assert.equal(fastTokens.some((token) => token.physicalHomeKey === "physical-b"), false);
  });
});

test("late resolved listener failure after unmount never schedules reconciliation", async () => {
  await withMountedDashboard(async ({ React, load, render }) => {
    const { emptyDashboardSnapshot, fallbackPlatformCapabilities } = await load("/src/api/fallback.ts");
    const subscription = deferred();
    let subscribeCalls = 0;
    let scheduleCalls = 0;
    const source = dashboardSource({
      emptyDashboardSnapshot,
      fallbackPlatformCapabilities,
      getCodexHome: () => Promise.resolve(sourceEnvelope("physical-a", 1)),
      readDashboardSnapshot: (token) => Promise.resolve(snapshot(emptyDashboardSnapshot, token.physicalHomeKey)),
    });
    const root = await render(source, {
      subscribeToSourceChanges() {
        subscribeCalls += 1;
        return subscription.promise;
      },
      scheduleSourceReconcile() {
        scheduleCalls += 1;
        return () => {};
      },
    });
    await waitForAct(React, () => subscribeCalls === 1);
    await React.act(async () => root.unmount());
    await React.act(async () => {
      subscription.resolve({ ok: false, error: "late failure" });
      await tick();
    });
    assert.equal(scheduleCalls, 0);
  });
});

test("late resolved healthy listener after unmount unlistens without scheduling", async () => {
  await withMountedDashboard(async ({ React, load, render }) => {
    const { emptyDashboardSnapshot, fallbackPlatformCapabilities } = await load("/src/api/fallback.ts");
    const subscription = deferred();
    let scheduleCalls = 0;
    let unlistenCalls = 0;
    const source = dashboardSource({
      emptyDashboardSnapshot,
      fallbackPlatformCapabilities,
      getCodexHome: () => Promise.resolve(sourceEnvelope("physical-a", 1)),
      readDashboardSnapshot: (token) => Promise.resolve(snapshot(emptyDashboardSnapshot, token.physicalHomeKey)),
    });
    const root = await render(source, {
      subscribeToSourceChanges: () => subscription.promise,
      scheduleSourceReconcile() {
        scheduleCalls += 1;
        return () => {};
      },
    });
    await React.act(async () => root.unmount());
    await React.act(async () => {
      subscription.resolve({
        ok: true,
        unlisten: () => {
          unlistenCalls += 1;
        },
      });
      await tick();
    });
    assert.equal(unlistenCalls, 1);
    assert.equal(scheduleCalls, 0);
  });
});

async function withMountedDashboard(run) {
  const window = new Window({ url: "http://localhost/" });
  const restore = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useDashboardData } = await load("/src/state/useDashboardData.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      let root = null;
      const render = async (source, options) => {
        root = createRoot(container);
        function Probe() {
          const result = useDashboardData({ ...options, source, liveRateEnabled: false });
          return React.createElement("output", null, JSON.stringify({
            physical: result.providerSourceKey.split(":").at(-1),
            generatedAt: result.state.dashboard?.generatedAt ?? null,
          }));
        }
        const probe = React.createElement(Probe);
        await React.act(async () => root.render(
          options.strict ? React.createElement(React.StrictMode, null, probe) : probe,
        ));
        return root;
      };
      try {
        await run({ React, container, load, render, window });
      } finally {
        if (root !== null) {
          await React.act(async () => root.unmount());
        }
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restore();
    window.close();
  }
}

function dashboardSource(options) {
  return {
    getCodexHome: options.getCodexHome,
    setCodexHome: async () => { throw new Error("unused"); },
    resetCodexHome: async () => { throw new Error("unused"); },
    readPlatformCapabilities: () => Promise.resolve(options.fallbackPlatformCapabilities),
    readDashboardSnapshot: options.readDashboardSnapshot,
    readPreciseDashboardSnapshot: options.readPreciseDashboardSnapshot ?? (() => Promise.resolve(null)),
    readPreciseDashboardSourceProbe: options.readPreciseDashboardSourceProbe
      ?? (() => Promise.resolve(null)),
    readUsageCacheStatus: () => Promise.resolve({ namespace: "test", initialized: true, initializedAt: null }),
    readAccountQuota: () => Promise.resolve(null),
    readLiveRateSnapshot: () => Promise.resolve(null),
    readLiveThreadOptions: () => Promise.resolve([]),
    acknowledgeUnreadSummary: () => Promise.resolve(null),
    scanProviderRepair: () => Promise.resolve(null),
  };
}

function snapshot(factory, generatedAt) {
  return { ...factory(), generatedAt };
}

function sourceEnvelope(physicalHomeKey, transitionGeneration) {
  return {
    codexHome: { path: "/same/.codex", exists: true, source: "settings" },
    canonicalHomeKey: "/same/.codex",
    physicalHomeKey,
    transitionGeneration,
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((next) => { resolve = next; });
  return { promise, resolve };
}

async function waitForAct(React, predicate) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (predicate()) return;
    await React.act(tick);
  }
  assert.fail("condition did not become true");
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function installDomGlobals(window) {
  const values = {
    document: window.document, window, navigator: window.navigator,
    Node: window.Node, Element: window.Element, HTMLElement: window.HTMLElement,
    Event: window.Event, MutationObserver: window.MutationObserver,
    localStorage: window.localStorage,
  };
  const previous = new Map();
  for (const [name, value] of Object.entries(values)) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
  }
  return () => {
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  };
}
