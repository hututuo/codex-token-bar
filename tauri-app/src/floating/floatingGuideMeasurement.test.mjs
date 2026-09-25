import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("mounted production guide reports resized cards and disconnects after closing", async () => {
  const dom = new Window({ url: "http://localhost/?surface=floating" });
  const previous = new Map();
  const observers = [];
  let bottom = 310;
  class Observer {
    constructor(callback) { this.callback = callback; this.nodes = []; this.disconnected = false; observers.push(this); }
    observe(node) { this.nodes.push(node); }
    disconnect() { this.disconnected = true; }
  }
  for (const [key, value] of Object.entries({ window: dom, document: dom.document,
    navigator: dom.navigator, HTMLElement: dom.HTMLElement, Event: dom.Event,
    ResizeObserver: Observer, getComputedStyle: dom.getComputedStyle.bind(dom), IS_REACT_ACT_ENVIRONMENT: true })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  }
  const nativeRect = dom.HTMLElement.prototype.getBoundingClientRect;
  dom.HTMLElement.prototype.getBoundingClientRect = function () {
    return { top: 0, bottom: this.classList.contains("floating-paging-guide-card") ? bottom : 180,
      x: 0, y: 0, width: 308, height: 180, left: 0, right: 308 };
  };
  let root;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { FloatingPagingGuide } = await load("/src/floating/FloatingPagingGuide.tsx");
      const container = dom.document.createElement("div"); dom.document.body.append(container);
      root = createRoot(container);
      const heights = [];
      const props = { page: "runningModels", isLastPage: true, error: null, saving: false,
        showsArrowGlyphs: false, targetX: 120, targetY: 60, pointerY: 65,
        calloutY: 55, calloutCardY: 100, modelTargetX: 267, modelTargetY: 60,
        modelTargetWidth: 70, onArrowVisibilityChange() {}, onAdvance() {},
        onHeightChange: height => heights.push(height) };
      await React.act(async () => root.render(React.createElement("main", { className: "floating-window-shell" },
        React.createElement("aside", { className: "floating-panel-surface", style: { "--floating-scale": 1 } },
          React.createElement(FloatingPagingGuide, props)))));
      assert.equal(heights.at(-1), 316);
      assert.equal(observers.length, 1);
      assert.equal(observers[0].nodes.length, 3);
      bottom = 340;
      await React.act(async () => observers[0].callback([]));
      assert.equal(heights.at(-1), 346);
      await React.act(async () => root.unmount()); root = null;
      assert.equal(observers[0].disconnected, true);
    });
  } finally {
    if (root) { const React = await import("react"); await React.act(async () => root.unmount()); }
    dom.HTMLElement.prototype.getBoundingClientRect = nativeRect;
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key];
    }
    dom.close();
  }
});
