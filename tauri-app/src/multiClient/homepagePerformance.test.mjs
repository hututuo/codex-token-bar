import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("unrelated live renders preserve the client scope memo boundary", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const restore = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { useClientScope } = await load("/src/multiClient/useClientScope.ts");
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let childRenders = 0;
      const HistoricalSurface = React.memo(function HistoricalSurface({ allowed }) {
        childRenders += 1;
        return React.createElement("span", null, allowed.join(","));
      });
      function LiveParent({ rateRevision }) {
        const scope = useClientScope();
        return React.createElement("div", { "data-live-revision": rateRevision },
          React.createElement(HistoricalSurface, { allowed: scope.allowed }));
      }
      try {
        await React.act(async () => root.render(React.createElement(LiveParent, { rateRevision: 0 })));
        for (let revision = 1; revision <= 20; revision += 1) {
          await React.act(async () => root.render(React.createElement(LiveParent, { rateRevision: revision })));
        }
        assert.equal(childRenders, 1, "20 unrelated live updates must not rebuild historical analytics");
        assert.equal(container.textContent, "codex");

        // A real source choice must still pass through the same memo boundary.
        await React.act(async () => {
          dom.localStorage.setItem("multiClient.displayScope.v1", "claudeCode");
          dom.dispatchEvent(new dom.Event("multiClient.displayScope.v1"));
        });
        assert.equal(container.textContent, "claudeCode");
        assert.equal(childRenders, 2);
        for (let revision = 21; revision <= 30; revision += 1) {
          await React.act(async () => root.render(React.createElement(LiveParent, { rateRevision: revision })));
        }
        assert.equal(childRenders, 2, "the changed scope must also stay stable during later live updates");
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    restore();
    dom.close();
  }
});

test("a real client publication updates all-scope membership before later live renders are memoized", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const restore = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  dom.localStorage.setItem("multiClient.displayScope.v1", "all");
  let resolveSnapshot;
  dom.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
  dom.__TAURI_INTERNALS__ = {
    transformCallback() { return 1; },
    async invoke(command) {
      if (command.startsWith("plugin:event|")) return 1;
      assert.equal(command, "refresh_multi_client_usage");
      return await new Promise(resolve => { resolveSnapshot = resolve; });
    },
  };
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { useClientScope } = await load("/src/multiClient/useClientScope.ts");
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let renders = 0;
      const HistoricalSurface = React.memo(function HistoricalSurface({ allowed }) {
        renders += 1;
        return React.createElement("span", null, allowed.join(","));
      });
      function Parent({ liveRevision }) {
        const scope = useClientScope();
        return React.createElement("div", { "data-live-revision": liveRevision },
          React.createElement(HistoricalSurface, { allowed: scope.allowed }));
      }
      try {
        await React.act(async () => root.render(React.createElement(Parent, { liveRevision: 0 })));
        assert.equal(container.textContent, "codex");
        assert.equal(typeof resolveSnapshot, "function");
        await React.act(async () => resolveSnapshot({
          preferences: [{ client: "claudeCode", enabled: true }], summaries: [],
          diagnostics: [], updatedAt: "2026-10-30T08:00:00Z",
        }));
        assert.equal(container.textContent, "codex,claudeCode",
          "the memo key must include real client availability changes");
        const publishedRenders = renders;
        for (let revision = 1; revision <= 10; revision += 1) {
          await React.act(async () => root.render(React.createElement(Parent, { liveRevision: revision })));
        }
        assert.equal(renders, publishedRenders);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    restore();
    dom.close();
  }
});

test("scoped analytics consumes the prepared aggregate without projecting source buckets again", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const restore = installDomGlobals(dom);
  try {
    const React = await import("react");
    const { renderToStaticMarkup } = await import("react-dom/server");
    await withSsrModules(async load => {
      const { emptyDashboardSnapshot } = await load("/src/api/fallback/dashboardFallback.ts");
      const { DashboardAnalyticsSection } = await load("/src/pages/dashboard/DashboardAnalyticsSection.tsx");
      const now = Math.floor(Date.now() / 300_000) * 300;
      const original = emptyDashboardSnapshot();
      original.generatedAt = new Date(now * 1000).toISOString();
      const prepared = { ...original, recentUsage24h: [point(now, 54321)] };
      let sourceBucketReads = 0;
      const clients = {
        preferences: [], summaries: [], todaySummaries: [], sevenDaySummaries: [],
        dailyBuckets: [], diagnostics: [], updatedAt: original.generatedAt,
        get trendBuckets() { sourceBucketReads += 1; return []; },
      };
      const markup = renderToStaticMarkup(React.createElement(DashboardAnalyticsSection, {
        dashboard: prepared, originalCodex: original, clients,
        allowed: ["codex", "claudeCode"], clientScoped: true,
        sharedAccountAttribution: null,
      }));
      assert.equal(sourceBucketReads, 0, "the parent has already prepared this complete aggregate");
      const output = dom.document.createElement("div");
      output.innerHTML = markup;
      assert.equal(output.querySelectorAll(".client-analytics").length, 1);
      assert.equal(output.querySelectorAll(".activity-section").length, 1);
      assert.equal(output.querySelectorAll(".ranking-section").length, 1);
      assert.match(output.querySelector("svg.usage-chart title").textContent, /5\.4万/,
        "analytics must display the supplied aggregate instead of a fresh empty projection");
      assert.match(output.textContent, /逐桶金额及额度反推保留 Codex 来源/);
    });
  } finally {
    restore();
    dom.close();
  }
});

function point(startUnix, tokens) {
  return {
    startUnix, label: new Date(startUnix * 1000).toISOString(), tokens, calls: 1,
    inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0,
    cacheHitRate: 0, fiveHourRemainingPercent: null, sevenDayRemainingPercent: null,
  };
}

function installDomGlobals(dom) {
  const previous = new Map();
  for (const [key, value] of Object.entries({
    window: dom, document: dom.document, navigator: dom.navigator,
    localStorage: dom.localStorage, HTMLElement: dom.HTMLElement, Event: dom.Event,
    IS_REACT_ACT_ENVIRONMENT: undefined,
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
