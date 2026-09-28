import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "./test/ssrHarness.mjs";

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

const tick = () => new Promise(resolve => setTimeout(resolve, 0));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
test("quota switch clears credentials history and keeps all local usage totals", async () => {
  await withSsrModules(async load => {
    const { clearAccountQuota } = await load("/src/state/clearAccountQuota.ts");
    const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
    const q = emptyAccountQuotaBundle();
    const point = { tokens: 12345, calls: 7, fiveHourRemainingPercent: 80, sevenDayRemainingPercent: 60, fiveHourCycleId: "old", sevenDayCycleId: "old" };
    const original = { source: "unchanged", dashboard: { ...q, stats: { totalTokens: 998877 }, usageSummary: { todayTokens: 12345 }, activityDays: [{ ...point, date: "2026-09-20" }], recentUsage24h: [point], recentUsage7d: [point], recentUsage30d: [point] } };
    original.dashboard.quota.resetCredit = { availableCount: 3, status: "old-account", credits: [{ cardId: "old" }] };
    const next = clearAccountQuota(original);
    assert.equal(next.source, original.source);
    assert.equal(next.dashboard.account, original.dashboard.account);
    assert.equal(next.dashboard.stats, original.dashboard.stats);
    assert.equal(next.dashboard.usageSummary, original.dashboard.usageSummary);
    for (const key of ["activityDays", "recentUsage24h", "recentUsage7d", "recentUsage30d"]) {
      assert.equal(next.dashboard[key][0].tokens, 12345);
      assert.equal(next.dashboard[key][0].calls, 7);
      assert.equal(next.dashboard[key][0].fiveHourRemainingPercent, null);
      assert.equal(next.dashboard[key][0].sevenDayCycleId, null);
    }
    assert.equal(next.dashboard.quota.resetCredit.availableCount, 0);
    assert.deepEqual(next.dashboard.quota.resetCredit.credits, []);
    assert.equal(original.dashboard.quota.resetCredit.availableCount, 3);
  });
});

test("A to B to A discards late quota and reset responses from the first A", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restore = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  let selection = { revision: 7, selectedId: "a", accounts: [{ id: "a", label: "A" }, { id: "b", label: "B" }] };
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
  window.__TAURI_INTERNALS__ = {
    transformCallback: () => 1, unregisterCallback: () => {},
    invoke: async (command, args) => {
      if (command === "list_quota_accounts") return selection;
      if (command === "select_quota_account") { selection = { ...selection, revision: selection.revision + 1, selectedId: args.id }; return selection; }
      return 1;
    },
  };
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { useCompactPanelQuota, emptyAccountQuotaBundle, changeQuotaAccount } = await load("/src/test/quotaAccountHarness.ts");
      const pendingQuota = [], pendingReset = [];
      const readQuota = () => { const d = deferred(); pendingQuota.push(d); return d.promise; };
      const readReset = () => { const d = deferred(); pendingReset.push(d); return d.promise; };
      const sourceToken = { canonicalHomeKey: "/synthetic", physicalHomeKey: "one", transitionGeneration: 1 };
      let latest;
      function Probe() {
        latest = useCompactPanelQuota({ active: true, enabled: true, sourceToken, initialDelayMs: 0, intervalMs: 600000 }, readQuota, readReset);
        return React.createElement("output", null, latest.account.displayName);
      }
      const container = window.document.createElement("div");
      const root = createRoot(container);
      const settle = async () => { for (let i=0;i<5;i++) await React.act(tick); };
      try {
        await React.act(async () => root.render(React.createElement(Probe))); await settle();
        const initial = emptyAccountQuotaBundle(); initial.account.displayName = "saved-A";
        await React.act(async () => pendingQuota.at(-1).resolve(initial));
        await settle(); assert.equal(latest.account.displayName, "saved-A");
        await React.act(async () => changeQuotaAccount("select_quota_account", { id: "a" })); await settle();
        const oldQuota = pendingQuota.at(-1), oldReset = pendingReset.at(-1);
        await React.act(async () => changeQuotaAccount("select_quota_account", { id: "b" })); await settle();
        assert.notEqual(pendingQuota.at(-1), oldQuota, "B must issue a new request");
        assert.notEqual(latest.account.displayName, "saved-A", "Switching must clear A immediately");
        const selectedB = emptyAccountQuotaBundle(); selectedB.account.displayName = "new-B";
        await React.act(async () => pendingQuota.at(-1).resolve(selectedB));
        await settle(); assert.equal(latest.account.displayName, "new-B");
        await React.act(async () => changeQuotaAccount("select_quota_account", { id: "a" })); await settle();
        const fresh = emptyAccountQuotaBundle(); fresh.account.displayName = "new-A";
        await React.act(async () => { pendingQuota.at(-1).resolve(fresh); pendingReset.at(-1).resolve({ successful: true, updatedAt: fresh.updatedAt, resetCredit: { availableCount: 2, status: "new-A", credits: [] }, warnings: [], diagnostics: [] }); });
        await settle(); assert.equal(latest.account.displayName, "new-A");
        const stale = emptyAccountQuotaBundle(); stale.account.displayName = "OLD-A";
        await React.act(async () => { oldQuota.resolve(stale); oldReset.resolve({ successful: true, updatedAt: fresh.updatedAt, resetCredit: { availableCount: 9, status: "OLD-A", credits: [] }, warnings: [], diagnostics: [] }); });
        await settle(); assert.equal(latest.account.displayName, "new-A"); assert.equal(latest.quota.resetCredit.availableCount, 2);
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally { delete globalThis.IS_REACT_ACT_ENVIRONMENT; restore(); window.close(); }
});
