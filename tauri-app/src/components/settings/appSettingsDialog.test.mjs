import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

const SETTINGS_CATEGORIES = [
  "常规",
  "显示面",
  "监控与额度",
  "悬浮窗",
  "内容与排序",
  "提醒与更新",
  "数据与维护",
];

test("global settings exposes seven categorized tabs and defaults to general", async () => {
  await withSsrModules(async (load) => {
    const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
    const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
    const html = renderToStaticMarkup(React.createElement(
      AppSettingsDialog,
      settingsProps(DEFAULT_FLOATING_SETTINGS),
    ));

    assert.match(html, /role="dialog"/);
    assert.match(html, /总体设置/);
    assert.match(html, /role="tablist"/);
    assert.equal(html.match(/role="tab"/g)?.length, SETTINGS_CATEGORIES.length);
    for (const category of SETTINGS_CATEGORIES) {
      assert.match(html, new RegExp(category));
    }
    assert.match(html, /aria-selected="true"/);
    assert.match(html, /role="tabpanel"/);
    assert.match(html, /开机自启/);
    assert.doesNotMatch(html, /删除本地数据/);
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

test("settings tabs switch by click and support ArrowUp, ArrowDown, Home, and End", async () => {
  await withMountedSettings(async ({ act, container, document, window }) => {
    assert.deepEqual(settingTabs(container).map(tabName), SETTINGS_CATEGORIES);
    assert.equal(tabName(selectedTab(container)), "常规");
    assert.match(activePanel(container).textContent, /开机自启/);

    const generalTab = tabByName(container, "常规");
    generalTab.focus();
    await pressKey(act, generalTab, "ArrowDown", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "显示面");
    assert.equal(document.activeElement, tabByName(container, "显示面"));

    await pressKey(act, document.activeElement, "ArrowUp", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "常规");
    assert.equal(document.activeElement, generalTab);

    await pressKey(act, generalTab, "End", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "数据与维护");
    assert.equal(document.activeElement, tabByName(container, "数据与维护"));

    await pressKey(act, document.activeElement, "Home", window);
    await flushAnimationFrame(act, window);
    assert.equal(tabName(selectedTab(container)), "常规");
    assert.equal(document.activeElement, generalTab);

    await click(act, tabByName(container, "内容与排序"), window);
    assert.equal(tabName(selectedTab(container)), "内容与排序");
    assert.match(activePanel(container).textContent, /速率|额度|雷达/);
  });
});

test("monitoring settings own the token-rate full scale control", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    await click(act, tabByName(container, "监控与额度"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /实时速率/);
    assert.match(panel.textContent, /额度刷新/);

    const fullScale = panel.querySelector('input[type="range"][aria-label*="速率"]');
    assert.ok(fullScale, "monitoring page should expose the token-rate full-scale range");
    assert.equal(fullScale.value, "200");
    await setRangeValue(act, fullScale, 260, window);
    assert.deepEqual(calls.tokenRateFullScale, [260]);
  });
});

test("maintenance settings expose safe data and repair actions without local-data deletion", async () => {
  await withMountedSettings(async ({ act, calls, container, window }) => {
    for (const category of SETTINGS_CATEGORIES) {
      await click(act, tabByName(container, category), window);
      assert.doesNotMatch(activePanel(container).textContent, /删除本地数据/);
    }

    await click(act, tabByName(container, "数据与维护"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /Codex 数据目录/);
    const codexHomeInput = panel.querySelector('input[aria-label="Codex 目录"]');
    assert.ok(codexHomeInput, "maintenance page should expose the Codex directory editor");
    assert.equal(codexHomeInput.value, "/Users/test/.codex");
    assert.match(panel.textContent, /会话消失修复/);
    assert.match(panel.textContent, /已连接 Codex 调试端口 9222/);

    await click(act, buttonWithText(panel, "重新连接"), window);
    assert.equal(calls.threadDeleteReconnect, 1);

    await click(act, buttonWithText(panel, "打开修复工具"), window);
    await flushAnimationFrame(act, window);
    assert.equal(calls.providerRepair, 1);
    assert.doesNotMatch(container.textContent, /删除本地数据/);
  });
});

test("maintenance defers first-time thread-delete enablement to the confirmed header flow", async () => {
  await withMountedSettings(async ({ act, container, window }) => {
    await click(act, tabByName(container, "数据与维护"), window);
    const panel = activePanel(container);
    assert.match(panel.textContent, /请回主界面启用/);
    assert.equal(buttonWithTextOrNull(panel, "重新连接"), null);
  }, {
    threadDeleteBridgeStatus: {
      connected: false,
      debugPort: null,
      message: "等待 Codex 调试连接（需以调试模式启动 Codex）",
    },
  });
});

test("settings closes by Escape, close button, and backdrop while restoring focus", async () => {
  await withMountedSettings(async ({ act, before, calls, container, document, render, window }) => {
    const closeButton = container.querySelector('button[aria-label="关闭总体设置"]');
    assert.ok(closeButton);
    assert.equal(document.activeElement, closeButton);

    await pressKey(act, closeButton, "Escape", window);
    assert.equal(calls.close, 1);

    await click(act, closeButton, window);
    assert.equal(calls.close, 2);

    const backdrop = container.querySelector(".app-settings-overlay");
    assert.ok(backdrop);
    await mouseDown(act, backdrop, window);
    assert.equal(calls.close, 3);

    await render({ open: false });
    assert.equal(container.querySelector('[role="dialog"]'), null);
    assert.equal(document.activeElement, before);
  });
});

async function withMountedSettings(run, initialOverrides = {}) {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { AppSettingsDialog } = await load("/src/components/settings/AppSettingsDialog.tsx");
      const { DEFAULT_FLOATING_SETTINGS } = await load("/src/floating/floatingSettings.ts");
      const container = window.document.createElement("div");
      const before = window.document.createElement("button");
      before.textContent = "before settings";
      window.document.body.append(before, container);
      before.focus();
      const root = createRoot(container);
      const calls = {
        close: 0,
        providerRepair: 0,
        threadDeleteReconnect: 0,
        tokenRateFullScale: [],
        update: 0,
      };
      let overrides = initialOverrides;
      const render = async (nextOverrides = {}) => {
        overrides = { ...overrides, ...nextOverrides };
        await React.act(async () => root.render(React.createElement(
          AppSettingsDialog,
          settingsProps(DEFAULT_FLOATING_SETTINGS, calls, overrides),
        )));
      };
      try {
        await render();
        await run({ act: React.act, before, calls, container, document: window.document, render, window });
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

function settingsProps(floatingSettings, calls = null, overrides = {}) {
  const noop = () => {};
  const callLog = calls ?? {
    close: 0,
    providerRepair: 0,
    threadDeleteReconnect: 0,
    tokenRateFullScale: [],
    update: 0,
  };
  return {
    appUpdateState: { kind: "idle", message: "已是最新版本" },
    autostartStatus: { available: true, enabled: true, status: "enabled", message: "已开启" },
    codexHome: { exists: true, path: "/Users/test/.codex", source: "auto" },
    displaySurfaces: {
      floatingWindowEnabled: true,
      liveRateEnabled: true,
      statusTrayLiveTextEnabled: true,
    },
    floatingSettings,
    liveRateEnabled: true,
    open: true,
    platform: platformCapabilities(),
    quotaRefreshIntervalMs: 60_000,
    threadDeleteBridgeStatus: {
      connected: true,
      debugPort: 9222,
      message: "已连接 Codex 调试端口 9222",
    },
    onCheckForUpdate: async () => { callLog.update += 1; },
    onClose: () => { callLog.close += 1; },
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onFloatingContentVisibilityChange: noop,
    onFloatingGradientChange: noop,
    onFloatingOpacityChange: noop,
    onFloatingScaleChange: noop,
    onFloatingTextToneChange: noop,
    onFloatingUnreadEffectChange: noop,
    onOpenProviderRepair: () => { callLog.providerRepair += 1; },
    onQuotaRefreshIntervalChange: async () => {},
    onReconnectThreadDelete: async () => { callLog.threadDeleteReconnect += 1; },
    onTokenRateFullScaleChange: (value) => { callLog.tokenRateFullScale.push(value); },
    onToggleAutostart: noop,
    onToggleFloating: noop,
    onToggleLiveRate: noop,
    onToggleStatusTray: noop,
    ...overrides,
  };
}

function platformCapabilities() {
  const available = (label) => ({ available: true, status: "ready", label, note: `${label}可用` });
  return {
    platform: "macos",
    shell: "zsh",
    floatingWindow: available("悬浮窗"),
    floatingTransparency: available("悬浮窗透明度"),
    floatingDrag: available("悬浮窗拖动"),
    floatingLock: available("悬浮窗锁定"),
    statusTray: available("状态栏"),
    statusTrayLiveText: available("状态栏数字"),
    autostart: available("开机自启"),
    notifications: available("通知"),
  };
}

function settingTabs(container) {
  return [...container.querySelectorAll('[role="tab"]')];
}

function tabByName(container, name) {
  const tab = settingTabs(container).find((candidate) => tabName(candidate) === name);
  assert.ok(tab, `settings tab ${name} should exist`);
  return tab;
}

function tabName(tab) {
  return tab.querySelector("strong")?.textContent?.trim() ?? tab.textContent.trim();
}

function selectedTab(container) {
  const selected = container.querySelector('[role="tab"][aria-selected="true"]');
  assert.ok(selected, "one settings tab should be selected");
  return selected;
}

function activePanel(container) {
  const panel = container.querySelector('[role="tabpanel"]');
  assert.ok(panel, "active settings tab should own a tabpanel");
  return panel;
}

function buttonWithText(container, text) {
  const matches = [...container.querySelectorAll("button")]
    .filter((button) => button.textContent?.includes(text));
  assert.equal(matches.length, 1, `expected one button containing ${text}`);
  return matches[0];
}

function buttonWithTextOrNull(container, text) {
  return [...container.querySelectorAll("button")]
    .find((button) => button.textContent?.includes(text)) ?? null;
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
    HTMLInputElement: window.HTMLInputElement,
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

async function mouseDown(act, target, window) {
  await act(async () => target.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true })));
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

async function flushAnimationFrame(act, window) {
  await act(async () => new Promise((resolve) => window.requestAnimationFrame(resolve)));
}

async function setRangeValue(act, input, value, window) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set;
  assert.ok(setter, "range value setter should exist");
  setter.call(input, String(value));
  await act(async () => input.dispatchEvent(new window.Event("input", { bubbles: true, cancelable: true })));
}
