import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("global settings centralizes general, surface, appearance, reminder, and content controls", async () => {
  await withSsrModules(async (load) => {
    const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const html = renderToStaticMarkup(React.createElement(AppSettingsDialog, settingsProps(DEFAULT_FLOATING_SETTINGS)));

    assert.match(html, /role="dialog"/);
    assert.match(html, /总体设置/);
    assert.match(html, /开机自启/);
    assert.match(html, /实时速率/);
    assert.match(html, /额度刷新/);
    assert.match(html, /悬浮窗：开/);
    assert.match(html, /状态栏数字：开/);
    assert.match(html, /调色盘/);
    assert.match(html, /提醒/);
    assert.match(html, /内容/);
    assert.match(html, /透明度/);
    assert.match(html, /大小/);
  });
});

test("global settings stays unmounted while closed", async () => {
  await withSsrModules(async (load) => {
    const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const html = renderToStaticMarkup(React.createElement(AppSettingsDialog, {
      ...settingsProps(DEFAULT_FLOATING_SETTINGS),
      open: false,
    }));
    assert.equal(html, "");
  });
});

function settingsProps(floatingSettings) {
  const noop = () => {};
  return {
    autostartStatus: { available: true, enabled: true, message: "已开启" },
    displaySurfaces: {
      floatingWindowEnabled: true,
      liveRateEnabled: true,
      statusTrayLiveTextEnabled: true,
    },
    floatingSettings,
    liveRateEnabled: true,
    open: true,
    platform: {
      floatingWindow: { available: true, note: "可用" },
      statusTray: { available: true, note: "可用" },
      statusTrayLiveText: { available: true, note: "可用" },
    },
    quotaRefreshIntervalMs: 60_000,
    onClose: noop,
    onFloatingContentVisibilityChange: noop,
    onFloatingGradientChange: noop,
    onFloatingOpacityChange: noop,
    onFloatingScaleChange: noop,
    onFloatingTextToneChange: noop,
    onFloatingUnreadEffectChange: noop,
    onQuotaRefreshIntervalChange: async () => {},
    onToggleAutostart: noop,
    onToggleFloating: noop,
    onToggleLiveRate: noop,
    onToggleStatusTray: noop,
  };
}
