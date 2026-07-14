import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("routine mounted startup never resets the shared live-rate monitor", async () => {
  await withMountedLiveRateFeed({}, async ({ invocations, snapshots, waitForStartup }) => {
    await waitForStartup();

    assert.equal(snapshots.length, 1);
    assert.equal(
      invocations.some(({ command }) => command === "reset_live_rate_monitor"),
      false,
    );
  });
});

test("mounted initial read uses strict IPC with the captured source token", async () => {
  await withMountedLiveRateFeed({}, async ({ invocations, sourceToken, waitForStartup }) => {
    await waitForStartup();

    assert.deepEqual(
      invocations.filter(({ command }) => command === "read_live_rate_snapshot"),
      [{
        command: "read_live_rate_snapshot",
        args: { selectedThreadId: null, sourceToken },
      }],
    );
  });
});

test("an external positive event wins over a delayed initial zero", async () => {
  const initial = deferred();
  let initialRequests = 0;
  await withMountedLiveRateFeed({
    invoke(command) {
      if (command === "read_live_rate_snapshot") {
        initialRequests += 1;
        return initial.promise;
      }
      return true;
    },
  }, async ({ emitLiveRate, snapshots, waitFor }) => {
    await waitFor(() => initialRequests === 1);
    await emitLiveRate(liveRateSnapshot(40, "external-positive"));
    assert.deepEqual(snapshots.map(({ threadTitle }) => threadTitle), ["external-positive"]);

    await initial.resolve(liveRateSnapshot(0, "delayed-initial-zero"));
    assert.deepEqual(snapshots.map(({ threadTitle }) => threadTitle), ["external-positive"]);
  });
});

test("a failed strict initial read publishes failure instead of a fallback zero", async () => {
  await withMountedLiveRateFeed({
    silenceExpectedWarnings: true,
    invoke(command) {
      if (command === "read_live_rate_snapshot") {
        throw new Error("strict initial read failed");
      }
      return true;
    },
  }, async ({ snapshots, waitForStartup }) => {
    await waitForStartup();

    assert.equal(snapshots.length, 1);
    assert.equal(snapshots[0].threadTitle, "实时速率启动失败");
    assert.equal(snapshots[0].warnings[0]?.source, "live_rate_stream");
    assert.match(snapshots[0].warnings[0]?.message ?? "", /strict initial read failed/);
  });
});

test("a failed initial read retains an external event that already succeeded", async () => {
  const initial = deferred();
  let initialRequests = 0;
  await withMountedLiveRateFeed({
    silenceExpectedWarnings: true,
    invoke(command) {
      if (command === "read_live_rate_snapshot") {
        initialRequests += 1;
        return initial.promise;
      }
      return true;
    },
  }, async ({ emitLiveRate, snapshots, waitFor }) => {
    await waitFor(() => initialRequests === 1);
    await emitLiveRate(liveRateSnapshot(32, "external-positive"));
    initial.reject(new Error("late initial timeout"));
    await waitFor(() => snapshots.length > 0);
    await flushAct();

    assert.deepEqual(snapshots.map(({ threadTitle }) => threadTitle), ["external-positive"]);
    assert.deepEqual(snapshots[0].warnings, []);
  });
});

test("StrictMode cleanup ignores the retired listener and releases its accepted lease", async () => {
  await withMountedLiveRateFeed({ strict: true }, async ({
    emitLiveRateAt,
    liveHandlers,
    snapshots,
    stoppedLeases,
    unlistenCalls,
    unmount,
    waitFor,
  }) => {
    await waitFor(() => liveHandlers.length === 2 && snapshots.length === 1);
    await emitLiveRateAt(0, liveRateSnapshot(99, "retired-listener"));
    assert.equal(snapshots.some(({ threadTitle }) => threadTitle === "retired-listener"), false);

    await emitLiveRateAt(1, liveRateSnapshot(20, "current-listener"));
    assert.equal(snapshots.at(-1).threadTitle, "current-listener");
    assert.deepEqual(unlistenCalls(), [1, 0]);

    await unmount();
    assert.deepEqual(unlistenCalls(), [1, 1]);
    assert.deepEqual(stoppedLeases, ["lease-1"]);
  });
});

test("source transition cleanup rejects a delayed initial read from the retired generation", async () => {
  const initialA = deferred();
  const initialB = deferred();
  await withMountedLiveRateFeed({
    invoke(command, args) {
      if (command !== "read_live_rate_snapshot") {
        return true;
      }
      return args.sourceToken.physicalHomeKey === "unix:10:20"
        ? initialA.promise
        : initialB.promise;
    },
  }, async ({
    invocations,
    renderSourceToken,
    snapshots,
    sourceToken,
    stoppedLeases,
    waitFor,
  }) => {
    await waitFor(() => invocations.some(({ command }) => command === "read_live_rate_snapshot"));
    const sourceB = {
      ...sourceToken,
      physicalHomeKey: "unix:30:40",
      transitionGeneration: sourceToken.transitionGeneration + 1,
    };
    await renderSourceToken(sourceB);
    await waitFor(() => invocations.filter(({ command }) => command === "read_live_rate_snapshot").length === 2);

    await initialB.resolve(liveRateSnapshot(12, "source-b-initial"));
    await waitFor(() => snapshots.some(({ threadTitle }) => threadTitle === "source-b-initial"));
    await initialA.resolve(liveRateSnapshot(88, "late-source-a-initial"));

    assert.equal(snapshots.some(({ threadTitle }) => threadTitle === "late-source-a-initial"), false);
    assert.deepEqual(stoppedLeases, ["lease-1"]);
  });
});

async function withMountedLiveRateFeed(options, run) {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const invocations = [];
  const invoke = options.invoke ?? ((command) => (
    command === "read_live_rate_snapshot"
      ? liveRateSnapshot(0, "initial-snapshot")
      : true
  ));
  window.__TAURI_INTERNALS__ = {
    invoke(command, args) {
      invocations.push({ command, args });
      return Promise.resolve().then(() => invoke(command, args));
    },
  };
  const previousWarn = console.warn;
  if (options.silenceExpectedWarnings) {
    console.warn = () => {};
  }

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useLiveRateFeed } = await load("/src/state/useLiveRateFeed.ts");
      const sourceToken = {
        canonicalHomeKey: "/captured/.codex",
        physicalHomeKey: "unix:10:20",
        transitionGeneration: 7,
      };
      const liveHandlers = [];
      const unlistens = [];
      const stoppedLeases = [];
      const startOptions = [];
      const snapshots = [];
      let leaseNumber = 0;
      let root = null;
      let didUnmount = false;
      const dependencies = {
        platform: {
          claimLiveRateOwnerSession: () => Promise.resolve(true),
          onLiveRateSnapshot(handler) {
            const index = liveHandlers.length;
            liveHandlers.push(handler);
            unlistens[index] = 0;
            return Promise.resolve(() => {
              unlistens[index] += 1;
            });
          },
          startLiveRateStreamCommand(start) {
            startOptions.push(start);
            leaseNumber += 1;
            return Promise.resolve({
              ok: true,
              value: { leaseId: `lease-${leaseNumber}`, registered: true },
            });
          },
          stopLiveRateStream(leaseId) {
            stoppedLeases.push(leaseId);
            return Promise.resolve(true);
          },
        },
      };
      const container = window.document.createElement("div");
      window.document.body.append(container);
      root = createRoot(container);

      function Probe({ activeSourceToken }) {
        useLiveRateFeed({
          active: true,
          selectedThreadId: "",
          sourceToken: activeSourceToken,
          onSnapshot(snapshot) {
            snapshots.push(snapshot);
          },
        }, dependencies);
        return React.createElement("output");
      }

      const unmount = async () => {
        if (didUnmount) {
          return;
        }
        didUnmount = true;
        await React.act(async () => root.unmount());
      };

      try {
        const renderSourceToken = async (activeSourceToken) => {
          const probe = React.createElement(Probe, { activeSourceToken });
          await React.act(async () => root.render(
            options.strict ? React.createElement(React.StrictMode, null, probe) : probe,
          ));
        };
        await renderSourceToken(sourceToken);
        const waitFor = (predicate) => waitForAct(React, predicate);
        await run({
          emitLiveRate: (snapshot) => React.act(async () => liveHandlers.at(-1)(snapshot)),
          emitLiveRateAt: (index, snapshot) => React.act(async () => liveHandlers[index](snapshot)),
          invocations,
          liveHandlers,
          renderSourceToken,
          snapshots,
          sourceToken,
          startOptions,
          stoppedLeases,
          unlistenCalls: () => [...unlistens],
          unmount,
          waitFor,
          waitForStartup: () => waitFor(() => snapshots.length > 0),
        });
      } finally {
        await unmount();
      }
    });
  } finally {
    console.warn = previousWarn;
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
}

function liveRateSnapshot(tokensPerSecond, threadTitle) {
  return {
    scopeLabel: "全会话",
    threadTitle,
    selectedThreadId: null,
    selectedThreadTitle: "未选择",
    selectedTokensPerSecond: 0,
    tokensPerSecond,
    totalTokens: 100,
    totalTokensToday: 10,
    requestsToday: 1,
    maxTokensPerSecond: 200,
    preciseEnabled: true,
    unreadSummary: {
      active: false,
      count: 0,
      label: "暂无未读完成会话",
      detail: "",
      source: "test",
    },
    warnings: [],
  };
}

function deferred() {
  let resolvePromise;
  let rejectPromise;
  const promise = new Promise((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return {
    promise,
    reject: rejectPromise,
    resolve: async (value) => {
      resolvePromise(value);
      await flushAct();
    },
  };
}

async function waitForAct(React, predicate) {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (predicate()) {
      return;
    }
    await React.act(flush);
  }
  assert.fail("condition did not become true");
}

function flushAct() {
  return flush();
}

function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

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
    localStorage: window.localStorage,
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
