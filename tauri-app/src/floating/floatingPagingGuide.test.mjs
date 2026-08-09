import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("floating paging guide keeps the panel draggable area isolated and exposes the arrow choice", async () => {
  const dom = new Window({ url: "http://localhost/?surface=floating" });
  const restoreGlobals = installDomGlobals(dom);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { FloatingPagingGuide } = await load("/src/floating/FloatingPagingGuide.tsx");
      const container = dom.document.createElement("div");
      dom.document.body.append(container);
      const root = createRoot(container);
      let arrowChanges = 0;
      let completions = 0;
      let dragStarts = 0;

      try {
        await React.act(async () => root.render(React.createElement("div", {
          onMouseDown: () => {
            dragStarts += 1;
          },
        }, React.createElement(FloatingPagingGuide, {
          error: null,
          saving: false,
          showsArrowGlyphs: false,
          targetX: 120,
          targetY: 60,
          onArrowVisibilityChange: (visible) => {
            arrowChanges += visible ? 1 : -1;
          },
          onComplete: () => {
            completions += 1;
          },
        }))));

        assert.match(container.textContent, /点两侧即可翻页/);
        assert.match(container.textContent, /点击阴影边缘试一下/);
        const card = container.querySelector(".floating-paging-guide-card");
        const checkbox = container.querySelector('input[type="checkbox"]');
        const button = container.querySelector("button");
        assert.ok(card);
        assert.ok(checkbox);
        assert.ok(button);
        assert.equal(checkbox.checked, false);

        await React.act(async () => card.dispatchEvent(new dom.MouseEvent("mousedown", {
          bubbles: true,
          cancelable: true,
        })));
        assert.equal(dragStarts, 0);

        await React.act(async () => checkbox.click());
        assert.equal(arrowChanges, 1);
        await React.act(async () => button.click());
        assert.equal(completions, 1);
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

test("floating paging guide is versioned, persists narrowly, and keeps hidden edge controls alive", async () => {
  const [windowSource, settingsClient, desktopEvents, styles, asset, provenance] = await Promise.all([
    readFile(new URL("./FloatingWindowApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../api/settingsClient.ts", import.meta.url), "utf8"),
    readFile(new URL("../platform/desktopEvents.ts", import.meta.url), "utf8"),
    readFile(new URL("../styles/global.css", import.meta.url), "utf8"),
    stat(new URL("../../public/floating-paging-touch.png", import.meta.url)),
    readFile(new URL("../../../OPEN_SOURCE_NOTICES.md", import.meta.url), "utf8"),
  ]);

  assert.match(windowSource, /CURRENT_FLOATING_PAGING_GUIDE_REVISION/);
  assert.match(windowSource, /completeFloatingPagingGuide\(pagingGuideShowsArrowGlyphs\)/);
  assert.match(windowSource, /onPageNavigation=\{\(\) => \{/);
  assert.match(settingsClient, /complete_floating_paging_guide/);
  assert.match(desktopEvents, /floating-paging-guide-completed/);
  assert.match(styles, /\.floating-page-switch\.is-glyph-hidden > span\s*{\s*opacity: 0;/);
  assert.match(styles, /\.floating-page-switch\s*{[\s\S]*?pointer-events: auto;/);
  assert.match(styles, /mask: url\("\/floating-paging-touch\.png"\)/);
  assert.match(styles, /calc\(-50% \+ var\(--floating-paging-guide-target-x\)\)/);
  assert.match(styles, /calc\(-50% - var\(--floating-paging-guide-target-x\)\)/);
  assert.doesNotMatch(styles, /color-mix\([^)]*var\(--floating-gradient-background\)/);
  assert.match(styles, /\.floating-topline strong\s*{[\s\S]*?font-size: calc\(22px \* var\(--floating-scale\)\);/);
  assert.match(styles, /\.floating-model-usage\s*{[\s\S]*?font-size: calc\(9\.7px \* var\(--floating-scale\)\);/);
  assert.match(styles, /\.floating-quota-bar\s*{[\s\S]*?font-size: calc\(10\.9px \* var\(--floating-scale\)\);/);
  assert.ok(asset.size > 0);
  assert.match(provenance, /Google Material Design Icons/);
  assert.match(provenance, /Apache License 2\.0/);
});

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
