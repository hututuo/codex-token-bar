import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
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

test("nested settings callout owns focus and Escape closes only the current layer", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
      const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      let closeCalls = 0;
      try {
        await React.act(async () => root.render(React.createElement(AppSettingsDialog, {
          ...settingsProps(DEFAULT_FLOATING_SETTINGS),
          onClose: () => { closeCalls += 1; },
        })));

        const paletteButton = buttonWithText(container, "调色盘");
        await click(React.act, paletteButton, window);
        assert.ok(container.querySelector('[role="dialog"][aria-label="悬浮窗样式"]'));
        assert.equal(window.document.activeElement?.getAttribute("aria-label"), "关闭");

        await pressKey(React.act, window.document.activeElement, "Tab", window, { shiftKey: true });
        assert.equal(window.document.activeElement?.textContent?.trim(), "恢复默认");
        await pressKey(React.act, window.document.activeElement, "Tab", window);
        assert.equal(window.document.activeElement?.getAttribute("aria-label"), "关闭");

        await pressKey(React.act, window.document.activeElement, "Escape", window);
        assert.equal(container.querySelector('[role="dialog"][aria-label="悬浮窗样式"]'), null);
        assert.ok(container.querySelector('[role="dialog"][aria-label="总体设置"]'));
        assert.equal(closeCalls, 0);
        assert.equal(window.document.activeElement, paletteButton);

        await pressKey(React.act, paletteButton, "Escape", window);
        assert.equal(closeCalls, 1);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
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

function buttonWithText(container, text) {
  const matches = [...container.querySelectorAll("button")]
    .filter((button) => button.textContent?.includes(text));
  assert.equal(matches.length, 1, `expected one button containing ${text}`);
  return matches[0];
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
    PointerEvent: window.PointerEvent,
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
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  };
}

async function click(act, target, window) {
  await act(async () => target.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true })));
}

async function pressKey(act, target, key, window, options = {}) {
  assert.ok(target);
  await act(async () => target.dispatchEvent(new window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key,
    ...options,
  })));
}
