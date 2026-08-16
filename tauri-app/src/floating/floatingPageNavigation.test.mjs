import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("floating model row switches share and cost without starting panel drag", async () => {
  const dom = new Window({ url: "http://localhost/?surface=floating" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { FloatingPanelSurface } = await load("/src/floating/FloatingPanelPreview.tsx");
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let dragStarts = 0;
      let pageNavigations = 0;

      try {
        await React.act(async () => root.render(React.createElement(FloatingPanelSurface, {
          onDragStart: () => {
            dragStarts += 1;
          },
          onPageNavigation: () => {
            pageNavigations += 1;
          },
          priceModel: "gpt56Luna",
          settings: floatingSettingsFixture(),
          snapshot: floatingSnapshotFixture(),
          unreadEffect: "off",
        })));

        const next = container.querySelector('button[aria-label="显示下一项"]');
        const previous = container.querySelector('button[aria-label="显示上一项"]');
        assert.ok(next);
        assert.ok(previous);
        assert.ok(container.querySelector(".floating-page-content"));
        assert.ok(container.querySelector(".floating-page-switch-frame"));
        assert.match(container.textContent, /Sol50%/);
        assert.doesNotMatch(container.textContent, /Sol\$3\.25/);
        assert.match(container.querySelector(".floating-model-usage")?.getAttribute("aria-label") ?? "", /占比/);
        assert.doesNotMatch(container.textContent, /费用/);
        const moreModels = container.querySelector(".floating-model-usage-more");
        assert.equal(moreModels?.textContent?.trim(), "+1");
        assert.match(moreModels?.getAttribute("title") ?? "", /5\.4 · 0 tokens · 占比 0%/);

        await React.act(async () => next.dispatchEvent(new dom.MouseEvent("mousedown", {
          bubbles: true,
          cancelable: true,
        })));
        assert.equal(dragStarts, 0);
        await React.act(async () => next.click());
        assert.equal(pageNavigations, 1);
        assert.match(container.textContent, /Sol\$3\.25/);
        assert.match(container.textContent, /Luna\$0\.32/);
        assert.doesNotMatch(container.textContent, /Sol50%/);
        assert.match(container.querySelector(".floating-model-usage")?.getAttribute("aria-label") ?? "", /费用/);
        assert.doesNotMatch(container.textContent, /费用/);

        await React.act(async () => previous.click());
        assert.equal(pageNavigations, 2);
        assert.match(container.textContent, /Sol50%/);
        assert.match(container.querySelector(".floating-model-usage")?.getAttribute("aria-label") ?? "", /占比/);

        await React.act(async () => root.render(React.createElement(FloatingPanelSurface, {
          onDragStart: () => {
            dragStarts += 1;
          },
          onPageNavigation: () => {
            pageNavigations += 1;
          },
          priceModel: "gpt56Luna",
          settings: floatingSettingsFixture(false),
          snapshot: floatingSnapshotFixture(),
          unreadEffect: "off",
        })));
        const hiddenPrevious = container.querySelector('button[aria-label="显示上一项"]');
        const hiddenNext = container.querySelector('button[aria-label="显示下一项"]');
        assert.ok(hiddenPrevious);
        assert.ok(hiddenNext);
        assert.equal(hiddenPrevious.classList.contains("is-glyph-hidden"), true);
        assert.equal(hiddenNext.classList.contains("is-glyph-hidden"), true);
        await React.act(async () => hiddenNext.click());
        assert.equal(pageNavigations, 3);
        assert.match(container.textContent, /Sol\$3\.25/);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    restoreGlobals();
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    dom.close();
  }
});

test("paged floating rows use the same short fade cadence and edge cue as Swift", async () => {
  const styles = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");
  assert.match(styles, /\.floating-page-content\s*\{[^}]*animation: floating-page-content-fade 160ms ease-out both;/);
  assert.match(styles, /@keyframes floating-page-content-fade/);
  assert.match(styles, /\.floating-page-switch-frame\s*\{[^}]*width: calc\(14px \* var\(--floating-scale\)\);[^}]*height: calc\(20px \* var\(--floating-scale\)\);[^}]*animation: floating-page-switch-cue 1\.8s ease-out;/);
  assert.match(styles, /@keyframes floating-page-switch-cue/);
  assert.match(styles, /\.floating-page-switch--previous\s*\{[^}]*left: 0;[^}]*justify-content: flex-start;/s);
  assert.match(styles, /\.floating-page-switch--next\s*\{[^}]*right: 0;[^}]*justify-content: flex-end;/s);
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\)[\s\S]*?\.floating-page-content\s*\{[^}]*animation: none;/);
});

function floatingSettingsFixture(showPageNavigationArrows = true) {
  return {
    opacity: 0.92,
    scale: 1,
    tokenRateFullScale: 200,
    unreadEffect: "off",
    gradientStart: "#ffffff",
    gradientEnd: "#daefff",
    gradientDirection: "135deg",
    gradientType: "linear",
    quotaColorMode: "adaptive",
    quotaFixedColor: "#1469cc",
    textTone: -1,
    pagingGuideRevision: 0,
    contentVisibility: {
      showRateAndBar: false,
      showUsageStatus: false,
      showMetrics: false,
      showRunningThreads: false,
      showTodayModelShare: true,
      showTodayModelCost: true,
      showQuota: false,
      showRadar: false,
      showCrowdRadar: false,
      showPageNavigationArrows,
      order: ["todayModelShare", "todayModelCost"],
      pagePairs: [["todayModelShare", "todayModelCost"]],
    },
  };
}

function floatingSnapshotFixture() {
  return {
    tokensPerSecond: 0,
    maxTokensPerSecond: 200,
    trendLabel: "",
    resetCreditLabel: "",
    totalTokensLabel: "总 220万",
    todayTokensLabel: "今 220万",
    requestsLabel: "次 2",
    todayModelBreakdowns: [
      {
        model: "gpt-5.6-sol",
        breakdown: {
          inputTokens: 500_000,
          cachedInputTokens: 500_000,
          outputTokens: 100_000,
          totalTokens: 1_100_000,
          calls: 1,
        },
      },
      {
        model: "gpt-5.6-luna",
        breakdown: {
          inputTokens: 1_000_000,
          cachedInputTokens: 0,
          outputTokens: 100_000,
          totalTokens: 1_100_000,
          calls: 1,
        },
      },
      {
        model: "gpt-5.6-terra",
        breakdown: {
          inputTokens: 1_000,
          cachedInputTokens: 0,
          outputTokens: 0,
          totalTokens: 1_000,
          calls: 1,
        },
      },
      {
        model: "codex-auto-review",
        breakdown: {
          inputTokens: 1_000,
          cachedInputTokens: 0,
          outputTokens: 0,
          totalTokens: 1_000,
          calls: 1,
        },
      },
      {
        model: "gpt-5.5",
        breakdown: {
          inputTokens: 1,
          cachedInputTokens: 0,
          outputTokens: 0,
          totalTokens: 1,
          calls: 1,
        },
      },
    ],
    fiveHourLabel: "5h",
    fiveHourAvailability: "unavailable",
    fiveHourRemainingPercent: null,
    fiveHourExpectedRemainingPercent: null,
    sevenDayLabel: "7d",
    sevenDayAvailability: "unavailable",
    sevenDayRemainingPercent: null,
    sevenDayExpectedRemainingPercent: null,
    unread: false,
    unreadSummary: { active: false, count: 0, label: "无未读", detail: "", source: "test" },
  };
}

function installDomGlobals(dom) {
  const previous = new Map();
  for (const [key, value] of Object.entries({
    window: dom,
    document: dom.document,
    navigator: dom.navigator,
    HTMLElement: dom.HTMLElement,
    Event: dom.Event,
    MouseEvent: dom.MouseEvent,
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
