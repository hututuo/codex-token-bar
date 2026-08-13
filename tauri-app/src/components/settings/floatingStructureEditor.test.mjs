import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
      let changeCount = 0;

      try {
        await React.act(async () => root.render(React.createElement(FloatingStructureEditor, {
          settings: DEFAULT_FLOATING_SETTINGS,
          snapshot: snapshotFixture(),
          runningThreads: runningThreadsFixture(),
          visibility: DEFAULT_FLOATING_SETTINGS.contentVisibility,
          onChange: (visibility) => {
            changeCount += 1;
            latestVisibility = visibility;
          },
        })));

        const handle = container.querySelector('button[aria-label^="拖动整行：速率"]');
        const target = container.querySelector('.fs-row[data-row-id="quota"]');
        const hidden = container.querySelector(".fs-hidden-zone");
        assert.ok(handle);
        assert.ok(target);
        assert.ok(hidden);
        const geometry = installEditorRects(container);
        const sourceRect = geometry.rowRects.get(handle.closest(".fs-row").dataset.rowId);
        const targetRect = geometry.rowRects.get(target.dataset.rowId);

        await React.act(async () => {
          handle.dispatchEvent(pointerEvent(dom, "pointerdown", {
            clientX: sourceRect.left + 12,
            clientY: sourceRect.top + 12,
          }));
          handle.dispatchEvent(pointerEvent(dom, "pointermove", {
            clientX: targetRect.left + 12,
            clientY: targetRect.top + 1,
          }));
        });
        assert.ok(container.querySelector(".floating-structure-shell.is-dragging"));
        assert.ok(container.querySelector(".fs-drop-gap.is-target"));
        const ghost = dom.document.body.querySelector(".fs-drag-ghost--row");
        assert.ok(ghost, "pointer dragging should render a complete floating row ghost");
        assert.match(ghost.textContent, /速率/);
        assert.match(ghost.textContent, /隐藏/);
        assert.match(ghost.style.transform, /^translate3d\(/);

        target.dispatchEvent(new dom.MouseEvent("mouseover", { bubbles: true }));
        assert.equal(target.classList.contains("is-selected"), false, "drag hover must not select an unrelated row");

        stubRect(target, makeRect(targetRect.left, targetRect.top + 80, targetRect.width, targetRect.height));
        await React.act(async () => handle.dispatchEvent(pointerEvent(dom, "pointermove", {
          clientX: targetRect.left + 12,
          clientY: targetRect.top + 1,
        })));
        assert.ok(
          target.parentElement.querySelector(".fs-drop-gap.is-target"),
          "the candidate slot must stay stable when its preview shifts live layout",
        );

        const shiftedHiddenRect = makeRect(
          geometry.hiddenRect.left,
          geometry.hiddenRect.top + 80,
          geometry.hiddenRect.width,
          geometry.hiddenRect.height,
        );
        stubRect(hidden, shiftedHiddenRect);
        await React.act(async () => handle.dispatchEvent(pointerEvent(dom, "pointermove", {
          clientX: shiftedHiddenRect.left + 12,
          clientY: shiftedHiddenRect.top + 12,
        })));
        assert.ok(hidden.classList.contains("is-drop-target"));
        assert.match(hidden.textContent, /松手即可隐藏/);

        // Selecting “已隐藏” collapses the previous item-sized gap and moves
        // this zone back up before pointerup. The visible target must remain
        // authoritative even when the pointer is now just outside the live rect.
        stubRect(hidden, geometry.hiddenRect);
        await React.act(async () => handle.dispatchEvent(pointerEvent(dom, "pointerup", {
          buttons: 0,
          clientX: shiftedHiddenRect.left + 12,
          clientY: shiftedHiddenRect.top + 12,
        })));
        assert.ok(latestVisibility);
        assert.equal(changeCount, 1);
        assert.equal(latestVisibility.showRateAndBar, false);
        assert.equal(latestVisibility.showUsageStatus, false);
        assert.ok(!hidden.classList.contains("is-drop-target"));
        assert.equal(dom.document.body.querySelector(".fs-drag-ghost"), null);
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

test("row dragging commits an optimistic order and keeps an item-sized target preview", async () => {
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
          onChange: (visibility) => { latestVisibility = visibility; },
        })));

        const source = container.querySelector('button[aria-label^="拖动整行：Radar"]');
        const target = container.querySelector('.fs-row[data-row-id="quota"]');
        assert.ok(source);
        assert.ok(target);
        const geometry = installEditorRects(container);
        const sourceRect = geometry.rowRects.get(source.closest(".fs-row").dataset.rowId);
        const targetRect = geometry.rowRects.get(target.dataset.rowId);

        await React.act(async () => {
          source.dispatchEvent(pointerEvent(dom, "pointerdown", {
            clientX: sourceRect.left + 12,
            clientY: sourceRect.top + 12,
          }));
          dom.dispatchEvent(pointerEvent(dom, "pointermove", {
            clientX: geometry.editorRect.left + 8,
            clientY: geometry.editorRect.top + 8,
          }));
          dom.dispatchEvent(pointerEvent(dom, "pointerup", {
            buttons: 0,
            clientX: geometry.editorRect.left + 8,
            clientY: geometry.editorRect.top + 8,
          }));
        });
        assert.equal(latestVisibility, null, "dropping on the editor title/padding must cancel");

        await React.act(async () => {
          source.dispatchEvent(pointerEvent(dom, "pointerdown", {
            clientX: sourceRect.left + 12,
            clientY: sourceRect.top + 12,
          }));
          dom.dispatchEvent(pointerEvent(dom, "pointermove", {
            clientX: targetRect.left + 12,
            clientY: targetRect.bottom - 1,
          }));
        });
        const preview = container.querySelector(".fs-drop-gap.is-target .fs-row-placeholder");
        assert.ok(preview);
        assert.match(preview.textContent, /Radar/);

        await React.act(async () => dom.dispatchEvent(pointerEvent(dom, "pointerup", {
          buttons: 0,
          clientX: targetRect.left + 12,
          clientY: targetRect.bottom - 1,
        })));
        assert.ok(latestVisibility);
        assert.ok(latestVisibility.order.indexOf("radar") > latestVisibility.order.indexOf("quota"));
        assert.equal(container.querySelector(".fs-drop-gap.is-target"), null);
        assert.ok(
          container.querySelectorAll(".fs-row")[container.querySelectorAll(".fs-row").length - 1]
            .textContent.includes("Radar"),
          "the editor should keep the dropped order even before persistence finishes",
        );
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

test("settings hierarchy uses a darker backdrop and distinct nested grey surfaces", () => {
  const styles = readFileSync(new URL("../../styles/global.css", import.meta.url), "utf8");
  assert.match(styles, /\.app-settings-overlay\s*{\s*background: rgba\(43, 51, 62, 0\.32\);/);
  assert.match(styles, /--settings-surface: #f4f6fa;/);
  assert.match(styles, /--settings-surface-raised: #f8fafc;/);
  assert.match(styles, /--settings-surface-muted: #e9edf4;/);
  assert.match(styles, /--settings-surface-inset: #e4e9f0;/);
  assert.match(styles, /\.fs-drop-gap\.is-target\s*{\s*height: calc\(var\(--fs-editor-row-height\) \+ var\(--fs-editor-gap-height\)\);/);
  assert.match(styles, /\.fs-drag-ghost\s*\{[^}]*position: fixed;[^}]*pointer-events: none;/s);
  assert.match(styles, /\.floating-structure-shell\.is-dragging \.fs-row\.is-drop-target\s*\{/);
});

test("page dragging shows an item-sized left or right slot and commits that page order", async () => {
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

        const radarChip = [...container.querySelectorAll("button.fs-chip")]
          .find((chip) => chip.textContent?.includes("Radar"));
        const crowdRow = container.querySelector('.fs-row[data-row-id="crowdRadar"]');
        assert.ok(radarChip);
        assert.ok(crowdRow);
        const geometry = installEditorRects(container);
        const sourceRect = geometry.rowRects.get(radarChip.closest(".fs-row").dataset.rowId);
        const targetRect = geometry.rowRects.get(crowdRow.dataset.rowId);
        const targetPagesRect = crowdRow.querySelector(".fs-row-pages").getBoundingClientRect();

        await React.act(async () => {
          radarChip.dispatchEvent(pointerEvent(dom, "pointerdown", {
            clientX: sourceRect.left + 100,
            clientY: sourceRect.top + 12,
          }));
          dom.dispatchEvent(pointerEvent(dom, "pointermove", {
            clientX: sourceRect.left + 108,
            clientY: sourceRect.top + 12,
          }));
          dom.dispatchEvent(pointerEvent(dom, "pointerup", {
            buttons: 0,
            clientX: sourceRect.left + 108,
            clientY: sourceRect.top + 12,
          }));
        });
        assert.equal(latestVisibility, null, "releasing a page inside its original row must not split the pair");

        await React.act(async () => {
          radarChip.dispatchEvent(pointerEvent(dom, "pointerdown", {
            clientX: sourceRect.left + 100,
            clientY: sourceRect.top + 12,
          }));
          radarChip.dispatchEvent(pointerEvent(dom, "pointermove", {
            clientX: targetPagesRect.left + 1,
            clientY: targetRect.top + 12,
          }));
        });
        let pageItems = [...crowdRow.querySelectorAll(".fs-row-pages > *")];
        assert.equal(pageItems[0].classList.contains("fs-chip--placeholder"), true);
        assert.match(pageItems[0].textContent, /Radar/);
        assert.equal(pageItems[0].textContent.includes("放这里"), false);
        assert.match(pageItems[1].textContent, /众测雷达/);

        await React.act(async () => radarChip.dispatchEvent(pointerEvent(dom, "pointermove", {
          clientX: targetPagesRect.right - 1,
          clientY: targetRect.top + 12,
        })));
        pageItems = [...crowdRow.querySelectorAll(".fs-row-pages > *")];
        assert.match(pageItems[0].textContent, /众测雷达/);
        assert.equal(pageItems[1].classList.contains("fs-chip--placeholder"), true);

        await React.act(async () => radarChip.dispatchEvent(pointerEvent(dom, "pointerup", {
          buttons: 0,
          clientX: targetPagesRect.right - 1,
          clientY: targetRect.top + 12,
        })));
        assert.ok(latestVisibility);
        assert.ok(latestVisibility.pagePairs.some((pair) => (
          pair[0] === "crowdRadar" && pair[1] === "radar"
        )));
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

function pointerEvent(dom, type, options = {}) {
  const event = new dom.PointerEvent(type, {
    bubbles: true,
    cancelable: true,
    button: 0,
    buttons: options.buttons ?? 1,
    clientX: options.clientX ?? 0,
    clientY: options.clientY ?? 0,
    isPrimary: true,
    pointerId: 7,
  });
  return event;
}

function installEditorRects(container) {
  const editor = container.querySelector(".floating-structure-editor");
  const rows = container.querySelector(".floating-structure-rows");
  const hidden = container.querySelector(".fs-hidden-zone");
  const rowRects = new Map();
  const editorRect = makeRect(0, 0, 620, 900);
  stubRect(editor, editorRect);
  stubRect(rows, makeRect(0, 20, 620, 720));
  [...container.querySelectorAll(".fs-row")].forEach((row, index) => {
    const rowRect = makeRect(20, 30 + index * 64, 560, 44);
    rowRects.set(row.dataset.rowId, rowRect);
    stubRect(row, rowRect);
    const pages = row.querySelector(".fs-row-pages");
    if (pages) stubRect(pages, makeRect(100, rowRect.top, 360, rowRect.height));
  });
  const hiddenRect = makeRect(20, 760, 560, 90);
  stubRect(hidden, hiddenRect);
  return { editorRect, hiddenRect, rowRects };
}

function makeRect(left, top, width, height) {
  return {
    bottom: top + height,
    height,
    left,
    right: left + width,
    top,
    width,
    x: left,
    y: top,
    toJSON() { return this; },
  };
}

function stubRect(node, rect) {
  Object.defineProperty(node, "getBoundingClientRect", {
    configurable: true,
    value: () => rect,
  });
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
    PointerEvent: dom.PointerEvent,
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
