import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";

function elements(node, result = []) {
  if (!node || typeof node !== "object") return result;
  if (Array.isArray(node)) { node.forEach(child => elements(child, result)); return result; }
  result.push(node); elements(node.props?.children, result); return result;
}
test("main display-surface shortcut exposes an independent sidebar toggle", async () => {
  await withSsrModules(async load => {
    const { LiveRateCard } = await load("/src/components/LiveRateCard.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const { emptyLiveRateSnapshot } = await load("/src/api/fallback/liveFallback.ts");
    let sidebarCalls = 0; let floatingCalls = 0;
    const props = { floatingSettings: DEFAULT_FLOATING_SETTINGS, floatingEnabled: false,
      quotaSidebarEnabled: true, onToggleQuotaSidebar: () => sidebarCalls++,
      onToggleFloating: () => floatingCalls++, platform: { floatingWindow: { available: true, note: "" }, statusTray: { available: true }, statusTrayLiveText: { available: true } },
      liveRateEnabled: false, snapshot: emptyLiveRateSnapshot(), statusTrayLiveTextEnabled: false };
    const tree = LiveRateCard(props);
    const sidebar = elements(tree).find(node => node.type === "button" && node.props.onClick === props.onToggleQuotaSidebar);
    assert.ok(sidebar); assert.equal(sidebar.props["aria-pressed"], true); assert.equal(sidebar.props.disabled, false);
    sidebar.props.onClick(); assert.equal(sidebarCalls, 1); assert.equal(floatingCalls, 0);
    const html = renderToStaticMarkup(React.createElement(LiveRateCard, props));
    assert.match(html, /quick-surface-label">额度侧栏/); assert.match(html, /quick-surface-label">悬浮窗/);
    const floating = elements(tree).find(node => node.type === "button" && node.props.onClick === props.onToggleFloating);
    assert.equal(floating.props["aria-pressed"], false);
  });
});
