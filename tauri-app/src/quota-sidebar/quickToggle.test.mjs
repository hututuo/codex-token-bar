import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("main display-surface shortcut exposes an independent sidebar toggle", async () => {
  const dom = new Window();
  const keys = ["window", "document", "navigator", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
  const previous = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) Object.defineProperty(globalThis, key, {configurable: true, writable: true,
    value: key === "IS_REACT_ACT_ENVIRONMENT" ? true : dom[key]});
  let root;
  try {
    const {createRoot} = await import("react-dom/client");
    root = createRoot(dom.document.body);
    await withSsrModules(async load => {
      const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
      const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
      const { emptyLiveRateSnapshot } = await load("/src/api/fallback/liveFallback.ts");
      let sidebarCalls = 0, floatingCalls = 0;
      const props = { floatingSettings: DEFAULT_FLOATING_SETTINGS, floatingEnabled: false,
        quotaSidebarEnabled: true, onToggleQuotaSidebar: () => sidebarCalls++,
        onToggleFloating: () => floatingCalls++, platform: { platform: "windows", floatingWindow: { available: true, note: "" }, statusTray: { available: true }, statusTrayLiveText: { available: true } },
        liveRateEnabled: false, snapshot: emptyLiveRateSnapshot(), statusTrayLiveTextEnabled: false };
      const render = value => React.act(async () => root.render(React.createElement(LiveRateCard, value)));
      await render(props);
      const sidebar = dom.document.querySelector('button[aria-label="额度侧栏"]');
      assert.ok(sidebar); assert.equal(sidebar.getAttribute("aria-pressed"), "true"); assert.equal(sidebar.disabled, false);
      await React.act(async () => sidebar.click());
      assert.equal(sidebarCalls, 1); assert.equal(floatingCalls, 0);
      assert.match(dom.document.body.innerHTML, /quick-surface-label">额度侧栏/);
      assert.match(dom.document.body.innerHTML, /quick-surface-label">悬浮窗/);
      assert.equal(dom.document.querySelector('button[aria-label="悬浮窗"]').getAttribute("aria-pressed"), "false");
      await render({...props, platform: {...props.platform, platform: "loading"}});
      assert.equal(dom.document.querySelector('button[aria-label="额度侧栏"]').disabled, true);
    });
  } finally {
    if (root) await React.act(async () => root.unmount());
    for (const [key, descriptor] of previous) descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key];
    dom.close();
  }
});
