import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("quota estimate keeps historical 5h beside 7d after the current 5h window disappears", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const recentUsage24h = [
        point(0, 0.82, 0.91),
        point(300, 0.78, 0.89),
        point(600, 0.74, 0.87),
      ];

      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h,
          recentUsage7d: [],
          recentUsage30d: [],
          fiveHourQuotaPresent: false,
          sevenDayQuotaPresent: true,
        })));

        assert.equal(container.querySelector('[role="dialog"]'), null);
        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        const cachePoints = chart.querySelectorAll("circle.chart-observation-point--hit");
        assert.equal(cachePoints.length, 3);
        assert.equal(cachePoints[0].getAttribute("r"), "1.6");
        chart.getBoundingClientRect = () => ({
          bottom: 185,
          height: 185,
          left: 0,
          right: 980,
          top: 0,
          width: 980,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        });

        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
          bubbles: true,
          cancelable: true,
          clientX: 120,
          clientY: 80,
          pointerId: 1,
        })));

        const estimate = container.querySelector('[role="dialog"][aria-label="额度估算"]');
        assert.ok(estimate);
        assert.equal(estimate.closest(".recent-chart-overlay-layer"), null);
        assert.ok(estimate.closest(".chart-section"));
        assert.equal(estimate.closest(".recent-chart-scroll-content"), null);
        assert.match(estimate.textContent, /5h/);
        assert.match(estimate.textContent, /7d/);
        assert.match(estimate.textContent, /无 5h 额度/);
        assert.doesNotMatch(estimate.textContent, /5h下降太小/);
        assert.doesNotMatch(estimate.textContent, /倍率/);
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

test("hover detail moves above the plot and disappears after an unpinned pointer leaves", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);

      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h: [point(0, 0.82, 0.91), point(300, 0.78, 0.89)],
          recentUsage7d: [],
          recentUsage30d: [],
        })));

        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        chart.getBoundingClientRect = () => ({
          bottom: 185,
          height: 185,
          left: 0,
          right: 980,
          top: 0,
          width: 980,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        });

        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointermove", {
          bubbles: true,
          clientX: 120,
          clientY: 80,
          pointerId: 1,
        })));
        assert.ok(container.querySelector(".chart-hover-bubble"));
        assert.equal(container.querySelector('[role="dialog"]'), null);

        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerout", {
          bubbles: true,
          clientX: 120,
          clientY: 0,
          pointerId: 1,
          relatedTarget: window.document.body,
        })));
        assert.equal(container.querySelector(".chart-hover-bubble"), null);
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

test("quota estimate adapts to seven-day-only history after the 5h window disappears", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const recentUsage24h = [
        point(0, null, 0.91),
        point(300, null, 0.89),
        point(600, null, 0.87),
      ];

      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h,
          recentUsage7d: [],
          recentUsage30d: [],
          fiveHourQuotaPresent: false,
          sevenDayQuotaPresent: true,
        })));

        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        chart.getBoundingClientRect = () => ({
          bottom: 185,
          height: 185,
          left: 0,
          right: 980,
          top: 0,
          width: 980,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        });

        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
          bubbles: true,
          cancelable: true,
          clientX: 120,
          clientY: 80,
          pointerId: 1,
        })));

        const estimate = container.querySelector('[role="dialog"][aria-label="额度估算"]');
        assert.ok(estimate);
        assert.doesNotMatch(estimate.textContent, /5h/);
        assert.match(estimate.textContent, /7d/);
        assert.doesNotMatch(estimate.textContent, /倍率/);
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

test("quota estimate keeps the range summary visible when quota stays at zero", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const recentUsage24h = [
        point(0, 0, 0),
        point(300, 0, 0),
        point(600, 0, 0),
      ];

      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h,
          recentUsage7d: [],
          recentUsage30d: [],
        })));

        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        chart.getBoundingClientRect = () => ({
          bottom: 185,
          height: 185,
          left: 0,
          right: 980,
          top: 0,
          width: 980,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        });

        for (const clientX of [0, 980]) {
          await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
            bubbles: true,
            cancelable: true,
            clientX,
            clientY: 80,
            pointerId: 1,
          })));
        }

        const estimate = container.querySelector('[role="dialog"][aria-label="额度估算"]');
        assert.ok(estimate);
        assert.match(estimate.textContent, /持续 15分钟/);
        assert.match(estimate.textContent, /5h降 0% · 不反推/);
        assert.match(estimate.textContent, /7d降 0% · 不反推/);
        assert.ok(container.querySelector(".chart-selection-range"));
        const selectionSummary = container.querySelector(".chart-selection-summary-bubble");
        assert.ok(selectionSummary);
        assert.match(selectionSummary.textContent, /选中区间/);
        assert.match(selectionSummary.textContent, /30\.0万/);
        assert.doesNotMatch(selectionSummary.textContent, /当前点/);
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

test("fixed 24h selection renders shared-account attribution in the lower result card", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const attributionContext = {
        status: "indistinguishable",
        priceBasis: "current",
        radarPlanTotalUSD: 100,
        quotaDataStale: false,
        radarDataStale: false,
        usagePendingQuotaRefresh: false,
        historyChangedLowConfidence: false,
        cycleStartUnix: 0,
        cycleEndUnix: 604_800,
        segmentStartUnix: 0,
        quotaUpdatedAtUnix: 600,
      };
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);

      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h: [point(0, 0.8, 0.90), point(300, 0.78, 0.88), point(600, 0.76, 0.87)],
          recentUsage7d: [],
          recentUsage30d: [],
          sharedAccountAttribution: attributionContext,
        })));
        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        chart.getBoundingClientRect = () => ({
          bottom: 185,
          height: 185,
          left: 0,
          right: 980,
          top: 0,
          width: 980,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        });

        for (const clientX of [0, 980]) {
          await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
            bubbles: true,
            cancelable: true,
            clientX,
            clientY: 80,
            pointerId: 1,
          })));
        }

        const attribution = container.querySelector('[aria-label="选区共享账号归因"]');
        assert.ok(attribution);
        assert.match(attribution.textContent, /账号实降3%/);
        assert.match(attribution.textContent, /本机折算≈1\.5%/);
        assert.match(attribution.textContent, /差额\+1\.5%/);

        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h: [point(0, 0.8, 0.90), point(300, 0.78, 0.88), point(600, 0.76, 0.87)],
          recentUsage7d: [],
          recentUsage30d: [],
          sharedAccountAttribution: { ...attributionContext, radarPlanTotalUSD: 10 },
        })));
        const negative = container.querySelector('[aria-label="选区共享账号归因"]');
        assert.ok(negative);
        assert.match(negative.textContent, /暂算差额-12%/);
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

test("fixed 24h selection keeps local conversion visible when quota history is missing", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h: [point(0, null, null), point(300, null, null)],
          recentUsage7d: [],
          recentUsage30d: [],
          sharedAccountAttribution: {
            status: "awaitingAccountSwitchBaseline",
            priceBasis: "radar20260730",
            radarPlanTotalUSD: 100,
            quotaDataStale: false,
            radarDataStale: false,
            usagePendingQuotaRefresh: false,
            historyChangedLowConfidence: false,
            cycleStartUnix: 0,
            cycleEndUnix: 604_800,
            segmentStartUnix: 0,
            quotaUpdatedAtUnix: 600,
          },
        })));
        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        chart.getBoundingClientRect = () => ({
          bottom: 185,
          height: 185,
          left: 0,
          right: 980,
          top: 0,
          width: 980,
          x: 0,
          y: 0,
          toJSON: () => ({}),
        });
        for (const clientX of [0, 980]) {
          await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
            bubbles: true,
            cancelable: true,
            clientX,
            clientY: 80,
            pointerId: 1,
          })));
        }
        const attribution = container.querySelector('[aria-label="选区共享账号归因"]');
        assert.ok(attribution);
        assert.match(attribution.textContent, /账号下降--/);
        assert.match(attribution.textContent, /本机折算≈1%/);
        assert.match(attribution.textContent, /暂算差额--/);
        const detail = container.querySelector('[aria-label="选区本机 API 等价金额"]');
        assert.ok(detail);
        assert.match(detail.textContent, /本机同基准 \$1\.00/);
        assert.match(detail.textContent, /当前 API \$1\.00/);
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

function point(startUnix, fiveHourRemainingPercent, sevenDayRemainingPercent) {
  return {
    label: "00:00",
    startUnix,
    tokens: 100_000,
    calls: 1,
    inputTokens: 100_000,
    cachedInputTokens: 0,
    outputTokens: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent,
    sevenDayRemainingPercent,
  };
}

test("24h hover and fixed selection preview expose model shares without persistent point clutter", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      try {
        await React.act(async () => root.render(React.createElement(RecentUsageChart, {
          recentUsage24h: [
            modelPoint(0, [["gpt-5.6-sol", 75_000], ["gpt-5.6-luna", 25_000]]),
            modelPoint(300, [["gpt-5.6-sol", 25_000], ["gpt-5.6-luna", 75_000]]),
          ],
          recentUsage7d: [],
          recentUsage30d: [],
        })));

        const chart = container.querySelector("svg.usage-chart");
        assert.ok(chart);
        assert.equal(chart.querySelectorAll(".chart-model-points circle").length, 0);
        chart.getBoundingClientRect = () => ({
          bottom: 185, height: 185, left: 0, right: 980, top: 0, width: 980, x: 0, y: 0,
          toJSON: () => ({}),
        });

        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointermove", {
          bubbles: true, clientX: 0, clientY: 80, pointerId: 1,
        })));
        assert.match(container.querySelector(".chart-hover-bubble")?.textContent ?? "", /Sol 75%/);
        assert.match(container.querySelector(".chart-hover-bubble")?.textContent ?? "", /Luna 25%/);

        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
          bubbles: true, cancelable: true, clientX: 0, clientY: 80, pointerId: 1,
        })));
        await React.act(async () => chart.dispatchEvent(new window.PointerEvent("pointerdown", {
          bubbles: true, cancelable: true, clientX: 980, clientY: 80, pointerId: 1,
        })));
        const selection = container.querySelector(".chart-selection-summary-bubble");
        assert.ok(selection);
        assert.match(selection.textContent, /Sol 50%/);
        assert.match(selection.textContent, /Luna 50%/);
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

function modelPoint(startUnix, models) {
  return {
    ...point(startUnix, null, null),
    modelBreakdowns: models.map(([model, totalTokens]) => ({
      model,
      breakdown: { inputTokens: totalTokens, cachedInputTokens: 0, outputTokens: 0, totalTokens, calls: 1 },
    })),
  };
}

test("quota estimate card follows the chart at the lower left like the Swift layout", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const cardRule = css.match(/\.chart-quota-estimate-card\s*\{(?<body>[\s\S]*?)\n\}/);
  assert.ok(cardRule?.groups?.body);
  assert.match(cardRule.groups.body, /position:\s*relative;/);
  assert.match(cardRule.groups.body, /margin-top:\s*18px;/);
  assert.doesNotMatch(cardRule.groups.body, /(?:^|\n)\s*top:/);
  assert.doesNotMatch(cardRule.groups.body, /(?:^|\n)\s*left:/);
})

test("hover detail keeps a clear gutter above the chart plot", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const bubbleRule = css.match(/\.chart-hover-bubble\s*\{(?<body>[\s\S]*?)\n\}/);
  assert.ok(bubbleRule?.groups?.body);
  assert.match(bubbleRule.groups.body, /top:\s*-2px;/);
  assert.match(bubbleRule.groups.body, /transform:\s*translate\(-50%,\s*-100%\);/);
});

function installDomGlobals(window) {
  const values = {
    document: window.document,
    window,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    SVGElement: window.SVGElement,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
    PointerEvent: window.PointerEvent,
    MutationObserver: window.MutationObserver,
    ResizeObserver: window.ResizeObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
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
