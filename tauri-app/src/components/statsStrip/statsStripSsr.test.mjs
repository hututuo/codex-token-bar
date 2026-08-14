import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("StatsStrip renders six historical metrics with an explainable savings estimate", async () => {
  await withSsrModules(async (load) => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: {
        totalTokens: 3_000_000,
        peakDayTokens: 1_000_000,
        peakThreadTokens: 2_000_000,
        currentStreakDays: 3,
        longestStreakDays: 8,
        totalCalls: 10,
        totalThreads: 2,
        totalInputTokens: 2_000_000,
        totalCachedInputTokens: 1_000_000,
        totalOutputTokens: 1_000_000,
        firstUsageAt: "2026-07-01T00:00:00Z",
      },
      todayTokens: 1_100_000,
      todayModelBreakdowns: [{
        model: "gpt-5.6-sol",
        breakdown: {
          inputTokens: 1_000_000,
          cachedInputTokens: 500_000,
          outputTokens: 100_000,
          totalTokens: 1_100_000,
          calls: 2,
        },
      }],
      recentUsage7d: [{
        label: "7d",
        startUnix: Math.floor(new Date("2026-07-07T00:00:00Z").getTime() / 1_000),
        tokens: 1_100_000,
        calls: 2,
        inputTokens: 1_000_000,
        cachedInputTokens: 500_000,
        outputTokens: 100_000,
        modelBreakdowns: [{
          model: "gpt-5.6-sol",
          breakdown: {
            inputTokens: 1_000_000,
            cachedInputTokens: 500_000,
            outputTokens: 100_000,
            totalTokens: 1_100_000,
            calls: 2,
          },
        }],
        cacheHitRate: null,
        fiveHourRemainingPercent: null,
        sevenDayRemainingPercent: null,
      }],
      sevenDayResetAtUnix: Math.floor(new Date("2026-07-08T00:00:00Z").getTime() / 1_000),
      planLabel: "Pro",
      warnings: [],
    }));

    assert.equal((html.match(/class="stats-cell/g) ?? []).length, 6);
    assert.match(html, /累计 Token 数/);
    assert.match(html, /累计薅到（估）/);
    assert.doesNotMatch(html, /金额统计范围/);
    assert.match(html, /本7d/);
    assert.match(html, /累计/);
    assert.match(html, /历史套餐或模型变化未计入/);
    assert.match(html, /模型费用范围/);
    assert.match(html, /各模型 API 等值费用/);
    assert.match(html, /Sol/);
    assert.match(html, /Terra/);
    assert.match(html, /Luna/);
    assert.match(html, /主力/);
    assert.equal((html.match(/stats-model-cost-primary-card/g) ?? []).length, 3);
    assert.match(html, /\$5\.75/);
    assert.match(html, /合计/);
  });
});

test("StatsStrip keeps model costs pending while precise usage is unavailable", async () => {
  await withSsrModules(async (load) => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: {
        totalTokens: 0,
        peakDayTokens: 0,
        peakThreadTokens: 0,
        currentStreakDays: 0,
        longestStreakDays: 0,
        totalCalls: 0,
        totalThreads: 0,
        totalInputTokens: 0,
        totalCachedInputTokens: 0,
        totalOutputTokens: 0,
        firstUsageAt: null,
      },
      todayTokens: 0,
      todayModelBreakdowns: [],
      preciseDataFresh: false,
      planLabel: "Pro",
      warnings: [{ source: "usage_precision", message: "精确统计准备中" }],
    }));

    assert.match(html, /本7d模型明细待读取/);
    assert.doesNotMatch(html, /今日暂无模型用量/);
  });
});

test("StatsStrip does not treat the initial warning-free placeholder as real zero usage", async () => {
  await withSsrModules(async (load) => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: {
        totalTokens: 0,
        peakDayTokens: 0,
        peakThreadTokens: 0,
        currentStreakDays: 0,
        longestStreakDays: 0,
        totalCalls: 0,
        totalThreads: 0,
      },
      todayTokens: 0,
      todayModelBreakdowns: [],
      preciseDataFresh: false,
      planLabel: "计划待读取",
      warnings: [],
    }));

    assert.match(html, /本7d模型明细待读取/);
    assert.doesNotMatch(html, /今日暂无模型用量/);
  });
});

test("StatsStrip model costs default to 7d and can switch back to cumulative", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const resetAtUnix = Math.floor(new Date("2026-07-08T00:00:00Z").getTime() / 1_000);
      const recentPoint = {
        label: "7d",
        startUnix: resetAtUnix - 60,
        tokens: 1_000_000,
        calls: 1,
        inputTokens: 1_000_000,
        cachedInputTokens: 0,
        outputTokens: 0,
        modelBreakdowns: [{
          model: "gpt-5.6-luna",
          breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
        }],
        cacheHitRate: null,
        fiveHourRemainingPercent: null,
        sevenDayRemainingPercent: null,
      };

      try {
        await React.act(async () => root.render(React.createElement(StatsStrip, {
          stats: {
            totalTokens: 1_000_000,
            peakDayTokens: 1_000_000,
            peakThreadTokens: 1_000_000,
            currentStreakDays: 1,
            longestStreakDays: 1,
            totalCalls: 1,
            totalThreads: 1,
            totalInputTokens: 1_000_000,
            totalCachedInputTokens: 0,
            totalOutputTokens: 0,
            modelBreakdowns: [{
              model: "gpt-5.6-terra",
              breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
            }],
            firstUsageAt: "2026-07-01T00:00:00Z",
          },
          todayTokens: 1_000_000,
          todayModelBreakdowns: [{
            model: "gpt-5.6-sol",
            breakdown: { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1 },
          }],
          recentUsage7d: [recentPoint],
          sevenDayResetAtUnix: resetAtUnix,
          planLabel: "Pro",
          warnings: [],
        })));

        const scope = container.querySelectorAll(".stats-model-cost-scope button");
        assert.equal(scope.length, 3);
        assert.equal(scope[0].textContent, "本7d");
        assert.equal(scope[0].getAttribute("aria-pressed"), "true");
        assert.match(container.textContent ?? "", /\$0\.20/);

        await React.act(async () => scope[2].dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
        assert.equal(scope[2].getAttribute("aria-pressed"), "true");
        assert.match(container.textContent ?? "", /\$2\.00/);
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
    SVGElement: window.SVGElement,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
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
