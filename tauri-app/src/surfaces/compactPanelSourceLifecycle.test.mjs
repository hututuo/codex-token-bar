import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("hidden compact surface evicts physical source A and rejects every delayed A publication", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { useCompactPanelSource } = await load("/src/surfaces/useCompactPanelSource.ts");
      const { useCompactPanelSnapshot } = await load("/src/surfaces/useCompactPanelSnapshot.ts");
      const sourceA = sourceEnvelope("physical-a", 1);
      const sourceB = sourceEnvelope("physical-b", 2);
      const delayedSummaryA = deferred();
      const delayedLiveA = deferred();
      const liveHandlers = [];
      const unreadHandlers = [];
      const claimedWith = [];
      const startedWith = [];
      const initialReads = [];
      let sourceListener = null;
      let summaryReads = 0;

      const sourceDependencies = {
        readCurrentSource: () => Promise.resolve(sourceA),
        subscribe(handler) {
          sourceListener = handler;
          return Promise.resolve(() => {});
        },
      };
      const snapshotDependencies = {
        platform: {
          claimLiveRateOwnerSession(_ownerToken, _ownerSessionEpoch, sourceToken) {
            claimedWith.push(sourceToken);
            return Promise.resolve(true);
          },
          onLiveRateSnapshot(handler) {
            liveHandlers.push(handler);
            return Promise.resolve(() => {});
          },
          onUnreadSummaryChanged(handler) {
            unreadHandlers.push(handler);
            return Promise.resolve(() => {});
          },
          startLiveRateStreamCommand(options) {
            startedWith.push(options.sourceToken);
            return Promise.resolve({
              ok: true,
              value: { leaseId: `lease-${startedWith.length}`, registered: true },
            });
          },
          stopLiveRateStream: () => Promise.resolve(true),
        },
        readInitialLiveRate(_selectedThreadId, sourceToken) {
          initialReads.push(sourceToken);
          return initialReads.length === 1
            ? delayedLiveA.promise
            : Promise.resolve(liveRateSnapshot({ tokensPerSecond: 7 }));
        },
        readUsageSummary(sourceToken) {
          summaryReads += 1;
          return sourceToken.physicalHomeKey === "physical-a"
            ? delayedSummaryA.promise
            : Promise.resolve({ totalTokens: 200, todayTokens: 20, todayRequests: 2 });
        },
      };
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);

      function Probe({ active }) {
        const sourceToken = useCompactPanelSource(sourceDependencies);
        const snapshot = useCompactPanelSnapshot({
          active,
          liveRateEnabled: true,
          liveRateOwnerToken: "source-lifecycle-test",
          sourceToken,
        }, snapshotDependencies);
        return React.createElement("output", null, JSON.stringify({
          physical: sourceToken?.physicalHomeKey ?? null,
          rate: snapshot.tokensPerSecond,
          total: snapshot.totalTokensLabel,
          unread: snapshot.unreadSummary.active,
        }));
      }
      const render = async (active) => {
        await React.act(async () => root.render(React.createElement(Probe, { active })));
      };
      const output = () => JSON.parse(container.textContent);

      try {
        await render(true);
        await waitForAct(React, () => (
          startedWith.length === 1
          && claimedWith.length === 1
          && initialReads.length === 1
          && liveHandlers.length === 1
          && unreadHandlers.length === 1
        ));
        assert.equal(startedWith[0].physicalHomeKey, "physical-a");
        assert.equal(claimedWith[0].physicalHomeKey, "physical-a");
        assert.equal(initialReads[0].physicalHomeKey, "physical-a");

        await React.act(async () => {
          liveHandlers[0](liveRateSnapshot({
            tokensPerSecond: 41,
            unreadSummary: unreadSummary(true, "source-a"),
          }));
        });
        assert.deepEqual(output(), {
          physical: "physical-a",
          rate: 41,
          total: "总 待读取",
          unread: true,
        });

        await render(false);
        assert.equal(output().rate, 41);
        await React.act(async () => {
          sourceListener(sourceB);
        });
        assert.deepEqual(output(), {
          physical: "physical-b",
          rate: 0,
          total: "总 待读取",
          unread: false,
        });

        await React.act(async () => {
          liveHandlers[0](liveRateSnapshot({
            tokensPerSecond: 99,
            unreadSummary: unreadSummary(true, "late-live-a"),
          }));
          unreadHandlers[0](unreadSummary(true, "late-unread-a"));
          delayedSummaryA.resolve({ totalTokens: 999, todayTokens: 99, todayRequests: 9 });
          delayedLiveA.resolve(liveRateSnapshot({ tokensPerSecond: 99 }));
          await tick();
        });
        assert.deepEqual(output(), {
          physical: "physical-b",
          rate: 0,
          total: "总 待读取",
          unread: false,
        });

        await render(true);
        await waitForAct(React, () => (
          startedWith.length === 2
          && claimedWith.length === 2
          && output().physical === "physical-b"
          && output().rate === 7
          && output().total === "总 200"
        ));
        assert.equal(startedWith[1].physicalHomeKey, "physical-b");
        assert.equal(claimedWith[1].physicalHomeKey, "physical-b");
        assert.equal(initialReads[1].physicalHomeKey, "physical-b");

        await render(true);
        await tick();
        assert.equal(startedWith.length, 2);
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

function sourceEnvelope(physicalHomeKey, transitionGeneration) {
  return {
    codexHome: {
      path: "/same/.codex",
      exists: true,
      source: "settings",
    },
    canonicalHomeKey: "/same/.codex",
    physicalHomeKey,
    transitionGeneration,
  };
}

function liveRateSnapshot(overrides = {}) {
  return {
    scopeLabel: "全会话",
    threadTitle: "等待输出",
    selectedThreadId: null,
    selectedThreadTitle: "未选择",
    selectedTokensPerSecond: 0,
    tokensPerSecond: 0,
    totalTokens: 0,
    totalTokensToday: 0,
    requestsToday: 0,
    maxTokensPerSecond: 200,
    preciseEnabled: true,
    unreadSummary: unreadSummary(false, "none"),
    warnings: [],
    ...overrides,
  };
}

function unreadSummary(active, source) {
  return {
    active,
    count: active ? 1 : 0,
    label: active ? "有未读" : "",
    detail: "",
    source,
  };
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

function deferred() {
  let resolve;
  const promise = new Promise((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

async function waitForAct(React, predicate) {
  for (let attempt = 0; attempt < 30; attempt += 1) {
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
