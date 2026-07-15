import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("LiveRateSettingsPanel exposes a stable floating-window accessible name", async () => {
  await withSsrModules(async (load) => {
    const { LiveRateSettingsPanel } = await load("/src/components/liveRate/LiveRateSettingsPanel.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const enabled = renderToStaticMarkup(React.createElement(LiveRateSettingsPanel, panelProps(DEFAULT_FLOATING_SETTINGS, true)));
    const disabled = renderToStaticMarkup(React.createElement(LiveRateSettingsPanel, panelProps(DEFAULT_FLOATING_SETTINGS, false)));

    assert.match(enabled, />悬浮窗：开<\/button>/);
    assert.match(disabled, />悬浮窗：关<\/button>/);
    assert.doesNotMatch(enabled, /显示：悬浮窗|显示：关闭/);
    assert.doesNotMatch(disabled, /显示：悬浮窗|显示：关闭/);
  });
});

test("content settings rows show Swift-style subtitles and movement feedback", async () => {
  const panel = await readFile(new URL("./LiveRateSettingsPanel.tsx", import.meta.url), "utf8");
  const labels = await readFile(new URL("../../floating/floatingContent.ts", import.meta.url), "utf8");

  assert.equal(panel.includes("label.subtitle"), true);
  assert.equal(labels.includes("靠近速率会吸附"), true);
  assert.equal(panel.includes("moveFloatingContent"), true);
  assert.equal(panel.includes("aria-live"), true);
  assert.equal(panel.includes("movedInfo"), true);
  assert.equal(panel.includes("已${movedInfo.direction === \"up\" ? \"上移\" : \"下移\"}"), true);
  assert.equal(panel.includes("data-move-direction"), true);
  assert.equal(panel.includes("向上移动"), true);
  assert.equal(panel.includes("向下移动"), true);
  assert.equal(panel.includes('["adaptive", "随均速"]'), true);
  assert.equal(panel.includes('["adaptive", "随百分比"]'), false);
});

function panelProps(floatingSettings, floatingEnabled) {
  const ready = (label) => ({ available: true, status: "ready", label, note: `${label}已接入` });
  return {
    floatingSettings,
    floatingEnabled,
    onFloatingGradientChange: () => {},
    onFloatingOpacityChange: () => {},
    onFloatingScaleChange: () => {},
    onFloatingTextToneChange: () => {},
    onFloatingContentVisibilityChange: () => {},
    onFloatingUnreadEffectChange: () => {},
    onToggleFloating: () => {},
    onToggleStatusTray: () => {},
    platform: {
      floatingWindow: ready("悬浮窗"),
      statusTray: ready("状态栏"),
      statusTrayLiveText: ready("状态栏实时数字"),
    },
    statusTrayLiveTextEnabled: true,
  };
}
