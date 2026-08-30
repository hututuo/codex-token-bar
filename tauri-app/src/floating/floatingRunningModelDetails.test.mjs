import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("main/sub count area is a click target that does not start panel drag", async () => {
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
      let activations = 0;
      let drags = 0;

      try {
        await React.act(async () => root.render(React.createElement(FloatingPanelSurface, {
          settings: floatingSettingsFixture(),
          snapshot: floatingSnapshotFixture(),
          runningThreads: runningSummaryFixture(),
          onDragStart: () => { drags += 1; },
          onRunningThreadsActivate: () => { activations += 1; },
          runningModelDetailsExpanded: false,
        })));

        const trigger = container.querySelector(".floating-running-model-trigger");
        assert.ok(trigger);
        assert.equal(trigger.getAttribute("aria-expanded"), "false");
        assert.match(trigger.textContent, /主 2子 1/);

        await React.act(async () => trigger.dispatchEvent(new dom.MouseEvent("mousedown", {
          bubbles: true,
          cancelable: true,
        })));
        assert.equal(drags, 0);
        await React.act(async () => trigger.click());
        assert.equal(activations, 1);
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

test("running model card renders model, effort, counts, and unresolved fallback", async () => {
  await withSsrModules(async (load) => {
    const React = await import("react");
    const { renderToStaticMarkup } = await import("react-dom/server");
    const {
      FLOATING_RUNNING_MODEL_GUIDE_DEMO,
      FloatingRunningThreadModelDetails,
      floatingRunningThreadSummaryForPresentation,
      runningThreadModelDisplayRows,
    } = await load("/src/floating/FloatingRunningThreadModelDetails.tsx");

    assert.deepEqual(runningThreadModelDisplayRows([
      { model: "gpt-5.6-sol", reasoningEffort: "ultra", count: 2 },
    ], 3).map((row) => [row.title, row.count]), [
      ["Sol · ultra", 2],
      ["配置同步中", 1],
    ]);

    assert.equal(
      floatingRunningThreadSummaryForPresentation(
        runningSummaryFixture(),
        true,
        "runningModels",
      ),
      FLOATING_RUNNING_MODEL_GUIDE_DEMO,
    );
    assert.equal(
      floatingRunningThreadSummaryForPresentation(
        runningSummaryFixture(),
        false,
        "runningModels",
      ).mainThreads,
      2,
    );

    const html = renderToStaticMarkup(React.createElement(
      FloatingRunningThreadModelDetails,
      { onClose: () => {}, summary: runningSummaryFixture() },
    ));
    assert.match(html, /运行模型详情/);
    assert.match(html, /Sol · ultra/);
    assert.match(html, /Luna · max/);
    assert.match(html, /×2/);
    assert.match(html, /aria-label="关闭运行模型详情"/);
  });
});

test("running model close button invokes the supplied dismiss action", async () => {
  const dom = new Window({ url: "http://localhost/?surface=floating" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { FloatingRunningThreadModelDetails } = await load(
        "/src/floating/FloatingRunningThreadModelDetails.tsx",
      );
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let closes = 0;

      try {
        await React.act(async () => root.render(React.createElement(
          FloatingRunningThreadModelDetails,
          { onClose: () => { closes += 1; }, summary: runningSummaryFixture() },
        )));
        const close = container.querySelector('[aria-label="关闭运行模型详情"]');
        assert.ok(close);
        await React.act(async () => close.click());
        assert.equal(closes, 1);
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

test("floating window dismisses running model details on blur and blank clicks", async () => {
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(new URL("./FloatingWindowApp.tsx", import.meta.url), "utf8");

  assert.match(source, /window\.addEventListener\("blur", closeForWindowBlur\)/);
  assert.match(source, /dismissRunningModelDetailsForOutsidePointer/);
  assert.match(source, /onMouseDownCapture=\{dismissRunningModelDetailsForOutsidePointer\}/);
});

test("running model details card keeps its border without an outer drop shadow", async () => {
  const { readFile } = await import("node:fs/promises");
  const css = await readFile(new URL("../styles/global.css", import.meta.url), "utf8");
  const block = css.match(/\.floating-running-model-details \{([\s\S]*?)\n\}/)?.[1];

  assert.ok(block);
  assert.match(css, /--floating-running-model-card-background: #fafdff/);
  assert.match(block, /border: 1px solid rgba\(255, 255, 255, 0\.92\)/);
  assert.match(block, /background: var\(--floating-running-model-card-background\)/);
  assert.doesNotMatch(block, /background: rgba\(255, 255, 255, 0\.965\)/);
  assert.match(block, /box-shadow: inset 0 1px 0 rgba\(255, 255, 255, 0\.88\)/);
  assert.doesNotMatch(block, /rgba\(17, 25, 38, 0\.19\)/);
});

test("running model details card derives a softened color from the floating theme", async () => {
  await withSsrModules(async (load) => {
    const {
      floatingPanelAppearance,
      floatingRunningModelCardBackground,
    } = await load("/src/floating/floatingPresentation.ts");
    const { style } = floatingPanelAppearance({
      opacity: 0.92,
      scale: 1,
      gradientStart: "#FAF9FF",
      gradientEnd: "#00C2EF",
      gradientDirection: "135deg",
      gradientType: "conic",
    });

    assert.equal(style["--floating-running-model-card-background"], "#dbf6fd");
    assert.equal(floatingRunningModelCardBackground("#ffffff", "#daefff"), "#fafdff");
    assert.equal(floatingRunningModelCardBackground("#000000", "#000000"), "#b8b8b8");
    assert.equal(floatingRunningModelCardBackground("#ffffff", "#ffffff"), "#ffffff");
  });
});

test("running-model guide keeps the panel overflow open outside paging demo mode", async () => {
  await withSsrModules(async (load) => {
    const React = await import("react");
    const { renderToStaticMarkup } = await import("react-dom/server");
    const { FloatingPanelSurface } = await load("/src/floating/FloatingPanelPreview.tsx");

    const html = renderToStaticMarkup(React.createElement(FloatingPanelSurface, {
      settings: floatingSettingsFixture(),
      snapshot: floatingSnapshotFixture(),
      guideMode: false,
      guideOverlayVisible: true,
      overlay: React.createElement("button", { type: "button" }, "开始体验"),
    }));

    assert.match(html, /data-guide-overlay-visible="true"/);
    assert.match(html, />开始体验<\/button>/);
  });
});

function runningSummaryFixture() {
  return {
    total: 3,
    mainThreads: 2,
    subagents: 1,
    mainModels: [
      { model: "gpt-5.6-sol", reasoningEffort: "ultra", count: 2 },
    ],
    subagentModels: [
      { model: "gpt-5.6-luna", reasoningEffort: "max", count: 1 },
    ],
    status: "ready",
    updatedAt: 0,
    detail: "当前运行 3 个线程",
    livenessLeaseHours: 24,
  };
}

function floatingSettingsFixture() {
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
    pagingGuideRevision: 5,
    contentVisibility: {
      showRateAndBar: false,
      showUsageStatus: false,
      showMetrics: true,
      showRunningThreads: true,
      showTodayModelShare: false,
      showTodayModelCost: false,
      showQuota: false,
      showRadar: false,
      showCrowdRadar: false,
      showPageNavigationArrows: false,
      order: ["metrics", "runningThreads"],
      pagePairs: [],
    },
  };
}

function floatingSnapshotFixture() {
  return {
    tokensPerSecond: 0,
    maxTokensPerSecond: 200,
    trendLabel: "",
    resetCreditLabel: "",
    totalTokensLabel: "总 10万",
    todayTokensLabel: "今 1万",
    requestsLabel: "次 3",
    todayModelBreakdowns: [],
    unread: false,
    unreadSummary: {
      active: false,
      count: 0,
      label: "无未读",
      detail: "",
      source: "test",
    },
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
