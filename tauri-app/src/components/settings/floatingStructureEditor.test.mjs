import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("structure dragging previews the nearest insertion slot and hides on drop", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { FloatingStructureEditor } = await load("/src/components/settings/FloatingStructureEditor.tsx");
      const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let latestVisibility = null;

      try {
        await React.act(async () => root.render(React.createElement(FloatingStructureEditor, {
          settings: DEFAULT_FLOATING_SETTINGS,
          snapshot: snapshotFixture(),
          runningThreads: runningThreadsFixture(),
          visibility: DEFAULT_FLOATING_SETTINGS.contentVisibility,
          onChange: (visibility) => {
            latestVisibility = visibility;
          },
        })));

        const handle = container.querySelector('button[aria-label^="拖动整行：速率"]');
        const target = container.querySelectorAll(".fs-row")[1];
        const targetGap = container.querySelectorAll(".fs-drop-gap")[2];
        const hidden = container.querySelector(".fs-hidden-zone");
        assert.ok(handle);
        assert.ok(target);
        assert.ok(targetGap);
        assert.ok(hidden);

        await React.act(async () => handle.dispatchEvent(dragEvent(dom, "dragstart")));
        assert.ok(container.querySelector(".floating-structure-shell.is-dragging"));
        await React.act(async () => targetGap.dispatchEvent(dragEvent(dom, "dragover")));
        assert.ok(container.querySelector(".fs-drop-gap.is-target"));

        await React.act(async () => hidden.dispatchEvent(dragEvent(dom, "dragover")));
        assert.ok(hidden.classList.contains("is-drop-target"));
        assert.match(hidden.textContent, /松手即可隐藏/);

        await React.act(async () => hidden.dispatchEvent(dragEvent(dom, "drop")));
        assert.ok(latestVisibility);
        assert.equal(latestVisibility.showRateAndBar, false);
        assert.equal(latestVisibility.showUsageStatus, false);
        assert.ok(!hidden.classList.contains("is-drop-target"));
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

function dragEvent(dom, type, options = {}) {
  const event = new dom.DragEvent(type, {
    bubbles: true,
    cancelable: true,
    clientY: options.clientY ?? 0,
  });
  Object.defineProperty(event, "dataTransfer", {
    configurable: true,
    value: new dom.DataTransfer(),
  });
  Object.defineProperty(event, "clientY", {
    configurable: true,
    value: options.clientY ?? 0,
  });
  return event;
}

function snapshotFixture() {
  return {
    tokensPerSecond: 0,
    maxTokensPerSecond: 200,
    trendLabel: "",
    resetCreditLabel: "",
    totalTokensLabel: "总 0",
    todayTokensLabel: "今 0",
    requestsLabel: "次 0",
    todayModelBreakdowns: [],
    fiveHourLabel: "5h 待读取",
    fiveHourAvailability: "unavailable",
    fiveHourRemainingPercent: null,
    fiveHourExpectedRemainingPercent: null,
    sevenDayLabel: "7d 待读取",
    sevenDayAvailability: "unavailable",
    sevenDayRemainingPercent: null,
    sevenDayExpectedRemainingPercent: null,
    unread: false,
    unreadSummary: { active: false, count: 0, label: "无未读", detail: "", source: "test" },
  };
}

function runningThreadsFixture() {
  return {
    total: 0,
    mainThreads: 0,
    subagents: 0,
    status: "ready",
    updatedAt: 1,
    detail: "test",
    livenessLeaseHours: 24,
  };
}

function installDomGlobals(dom) {
  const previous = new Map();
  for (const [key, value] of Object.entries({
    window: dom,
    document: dom.document,
    navigator: dom.navigator,
    Node: dom.Node,
    HTMLElement: dom.HTMLElement,
    Event: dom.Event,
    MouseEvent: dom.MouseEvent,
    DragEvent: dom.DragEvent,
    DataTransfer: dom.DataTransfer,
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
