import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("focused cell removal transfers DOM focus to the valid fallback", async () => {
  await withMountedHeatmap(async ({ act, container, document, render, window }) => {
    const hoverEvents = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));

    await act(async () => heatmapCells(container).at(-1).focus());
    await pressKey(act, document.activeElement, "Home", window);
    await pressKey(act, document.activeElement, "ArrowRight", window);
    assert.equal(cellDate(document.activeElement), days[7].day.date);
    await pressKey(act, document.activeElement, "Home", window);

    await render(days.slice(1), (day) => hoverEvents.push(day?.date ?? null));

    const cells = heatmapCells(container);
    assert.equal(cellDate(document.activeElement), days.at(-1).day.date);
    assert.deepEqual(cells.filter((cell) => cell.tabIndex === 0), [document.activeElement]);
    assert.equal(hoverEvents.at(-1), days.at(-1).day.date);
  });
});

test("rerender does not reclaim focus after focus moves outside the group", async () => {
  await withMountedHeatmap(async ({ act, container, document, render, window }) => {
    const hoverEvents = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));

    await act(async () => heatmapCells(container).at(-1).focus());
    await pressKey(act, document.activeElement, "Home", window);
    const outside = document.createElement("button");
    document.body.append(outside);
    await act(async () => outside.focus());
    assert.equal(hoverEvents.at(-1), null);

    await render(days.slice(1), (day) => hoverEvents.push(day?.date ?? null));

    assert.equal(document.activeElement, outside);
    assert.equal(heatmapCells(container).filter((cell) => cell.tabIndex === 0).length, 1);
    assert.equal(hoverEvents.at(-1), null);
  });
});

test("relatedTarget null clears focus ownership before a removed-cell rerender", async () => {
  await withMountedHeatmap(async ({ act, container, document, render, window }) => {
    const hoverEvents = [];
    const relatedTargets = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));

    await act(async () => heatmapCells(container).at(-1).focus());
    await pressKey(act, document.activeElement, "Home", window);
    const focused = document.activeElement;
    focused.addEventListener("focusout", (event) => relatedTargets.push(event.relatedTarget));
    await act(async () => focused.blur());
    assert.equal(relatedTargets.at(-1), null);

    await render(days.slice(1), (day) => hoverEvents.push(day?.date ?? null));

    assert.equal(document.activeElement, document.body);
    assert.equal(heatmapCells(container).filter((cell) => cell.tabIndex === 0).length, 1);
    assert.equal(hoverEvents.at(-1), null);
  });
});

test("rerender preserves an existing focused cell without refocusing it", async () => {
  await withMountedHeatmap(async ({ act, container, document, render, window }) => {
    const hoverEvents = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));

    await act(async () => heatmapCells(container).at(-1).focus());
    await pressKey(act, document.activeElement, "Home", window);
    await pressKey(act, document.activeElement, "ArrowRight", window);
    const focused = document.activeElement;
    const hoverCount = hoverEvents.length;

    await render(days.map(({ day, intensity }) => ({
      day: { ...day, tokens: day.tokens + 1 },
      intensity,
    })), (day) => hoverEvents.push(day?.date ?? null));

    assert.equal(document.activeElement, focused);
    assert.equal(cellDate(focused), days[7].day.date);
    assert.equal(hoverEvents.length, hoverCount);
    assert.equal(heatmapCells(container).filter((cell) => cell.tabIndex === 0).length, 1);
  });
});

test("layout focus transfer reads ownership acquired after render", async () => {
  await withMountedHeatmap(async ({
    container,
    document,
    HeatmapGrid,
    React,
    renderElement,
    window,
  }) => {
    const days = calendarDays();
    function AcquireFocusOwnership({ enabled }) {
      React.useLayoutEffect(() => {
        if (!enabled) {
          return;
        }
        container.querySelector('[role="group"]').dispatchEvent(new window.FocusEvent("focusin", {
          bubbles: true,
          relatedTarget: document.body,
        }));
      }, [enabled]);
      return null;
    }
    const renderTree = (nextDays, acquireFocus) => React.createElement(
      React.Fragment,
      null,
      React.createElement(AcquireFocusOwnership, { enabled: acquireFocus }),
      React.createElement(HeatmapGrid, heatmapProps(nextDays, () => {})),
    );

    await renderElement(renderTree(days, false));
    assert.equal(document.activeElement, document.body);

    await renderElement(renderTree(days.slice(0, -1), true));

    assert.equal(cellDate(document.activeElement), days.at(-2).day.date);
    assert.deepEqual(
      heatmapCells(container).filter((cell) => cell.tabIndex === 0),
      [document.activeElement],
    );
  });
});

async function withMountedHeatmap(run) {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { HeatmapGrid } = await load("/src/components/tokenActivity/HeatmapGrid.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const renderElement = async (element) => {
        await React.act(async () => root.render(element));
      };
      const render = async (days, onDayHover) => {
        await renderElement(React.createElement(HeatmapGrid, heatmapProps(days, onDayHover)));
      };
      try {
        await run({
          act: React.act,
          container,
          document: window.document,
          HeatmapGrid,
          React,
          render,
          renderElement,
          window,
        });
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
}

function installDomGlobals(window) {
  const values = {
    document: window.document,
    window,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    HTMLButtonElement: window.HTMLButtonElement,
    Event: window.Event,
    FocusEvent: window.FocusEvent,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
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

async function pressKey(act, target, key, window) {
  await act(async () => {
    target.dispatchEvent(new window.KeyboardEvent("keydown", {
      bubbles: true,
      cancelable: true,
      key,
    }));
  });
}

function heatmapProps(days, onDayHover) {
  return {
    days,
    hoveredDate: null,
    mode: "daily",
    monthMarkers: [],
    onDateSelect() {},
    onDayHover,
    rangeEnd: null,
    rangeStart: null,
  };
}

function heatmapCells(container) {
  return [...container.querySelectorAll(".heatmap-cell")];
}

function cellDate(cell) {
  return cell?.getAttribute("aria-label")?.slice(0, 10) ?? null;
}

function calendarDays() {
  const start = new Date(2026, 0, 1, 12);
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date(start);
    date.setDate(start.getDate() + index);
    return {
      day: {
        cacheHitRate: 0,
        calls: index === 364 ? 1 : 0,
        date: dateKey(date),
        fiveHourRemainingPercent: null,
        sevenDayRemainingPercent: null,
        tokens: index === 364 ? 100 : 0,
      },
      intensity: index === 364 ? 1 : 0,
    };
  });
}

function dateKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
