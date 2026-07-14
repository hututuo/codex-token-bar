import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("DashboardHeader more-actions menu preserves behavior and keyboard dismissal", async () => {
  await withMountedHeader(async ({ act, container, document, render, window, calls }) => {
    assert.deepEqual(visibleButtonNames(container), [
      "立即刷新",
      "检查更新",
      "开机自启：关",
      "更改目录",
      "会话消失修复",
      "启用会话删除",
      "更多操作",
    ]);

    await click(act, buttonByName(container, "检查更新"), window);
    assert.equal(calls.update, 1);

    await click(act, buttonByName(container, "更多操作"), window);
    assert.equal(buttonByName(container, "更多操作").getAttribute("aria-expanded"), "true");
    assert.deepEqual(menuButtonNames(container), ["导出 CSV", "导出 PNG"]);

    await render({ appUpdateState: { kind: "available", message: "发现新版本 v0.7.4" } });
    assert.equal(buttonByName(container, "安装更新").title, "发现新版本 v0.7.4");
    assert.ok(container.querySelector('[role="menu"]'), "update state rerender keeps the export menu open");

    await pressKey(act, document.activeElement, "Escape", window);
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, /更多操作/), window);
    await act(async () => document.body.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true })));
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, /更多操作/), window);
    await click(act, buttonByName(container, "导出 CSV"), window);
    assert.equal(calls.csv, 1);
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(document.activeElement, buttonByName(container, /更多操作/));

    await click(act, buttonByName(container, /更多操作/), window);
    await click(act, buttonByName(container, "导出 PNG"), window);
    assert.equal(calls.png, 1);
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(document.activeElement, buttonByName(container, /更多操作/));

    const reconnect = buttonByName(container, "启用会话删除");
    assert.equal(reconnect.title, "等待 Codex 调试连接（需以调试模式启动 Codex）");
    await click(act, reconnect, window);
    assert.ok(container.querySelector('[role="alertdialog"]'));
    assert.equal(document.activeElement.textContent.trim(), "取消");
    assert.equal(calls.threadDeleteReconnect, 0);
    await pressKey(act, document.activeElement, "Tab", window, { shiftKey: true });
    assert.equal(document.activeElement.textContent.trim(), "重启并启用");
    await pressKey(act, document.activeElement, "Tab", window);
    assert.equal(document.activeElement.textContent.trim(), "取消");
    await pressKey(act, document.activeElement, "Escape", window);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);
    assert.equal(document.activeElement, reconnect);

    await click(act, reconnect, window);
    await click(act, buttonByName(container, "取消"), window);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);
    assert.equal(document.activeElement, reconnect);

    await click(act, reconnect, window);
    await click(act, buttonByName(container, "重启并启用"), window);
    assert.equal(calls.threadDeleteReconnect, 1);
    assert.equal(container.querySelector('[role="alertdialog"]'), null);
    assert.equal(container.querySelector('[role="menu"]'), null);
  });
});

test("DashboardHeader keeps primary autostart visible, disabled, and explained", async () => {
  await withMountedHeader(async ({ container }) => {
    const autostart = buttonByName(container, "开机自启：关");
    assert.equal(autostart.disabled, true);
    assert.equal(autostart.getAttribute("aria-pressed"), "false");
    assert.equal(autostart.title, "当前平台不支持开机自启");
    const help = container.querySelector(`#${autostart.getAttribute("aria-describedby")}`);
    assert.match(help?.textContent, /当前平台不支持/);
  }, {
    autostartStatus: { available: false, enabled: false, message: "当前平台不支持开机自启" },
  });
});

test("DashboardHeader menu implements composite focus and keyboard navigation", async () => {
  await withMountedHeader(async ({ act, after, container, document, window }) => {
    const trigger = buttonByName(container, "更多操作");
    trigger.focus();
    await pressKey(act, trigger, "Enter", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 CSV");
    assert.equal(menuItems(container).filter((item) => item.tabIndex === 0).length, 0);

    await pressKey(act, document.activeElement, "ArrowDown", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 PNG");
    await pressKey(act, document.activeElement, "End", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 PNG");
    await pressKey(act, document.activeElement, "ArrowDown", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 CSV");
    await pressKey(act, document.activeElement, "ArrowUp", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 PNG");
    await pressKey(act, document.activeElement, "Home", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 CSV");

    await pressKey(act, document.activeElement, "Escape", window);
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(document.activeElement, trigger);

    await pressKey(act, trigger, " ", window);
    await pressKey(act, document.activeElement, "Tab", window);
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(document.activeElement, after);

    trigger.focus();
    await pressKey(act, trigger, "ArrowUp", window);
    assert.equal(document.activeElement.textContent.trim(), "导出 PNG");
    await pressKey(act, document.activeElement, "Tab", window, { shiftKey: true });
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(document.activeElement.textContent.trim(), "启用会话删除");

    trigger.focus();
    await pressKey(act, trigger, "ArrowDown", window);
    await act(async () => after.focus());
    assert.equal(container.querySelector('[role="menu"]'), null);
    assert.equal(document.activeElement, after);

    trigger.focus();
    await pressKey(act, trigger, "ArrowDown", window);
    await act(async () => document.activeElement.dispatchEvent(new window.FocusEvent("focusout", {
      bubbles: true,
      relatedTarget: null,
    })));
    assert.equal(Boolean(container.querySelector('[role="menu"]')), false, "window/document blur closes the menu");
  });
});

async function withMountedHeader(run, initialOverrides = {}) {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { DashboardHeader } = await load("/src/components/DashboardHeader.tsx");
      const container = window.document.createElement("div");
      const before = window.document.createElement("button");
      before.textContent = "before header";
      const after = window.document.createElement("button");
      after.textContent = "after header";
      window.document.body.append(before, container, after);
      const root = createRoot(container);
      const calls = { autostart: 0, csv: 0, png: 0, threadDeleteReconnect: 0, update: 0 };
      let overrides = initialOverrides;
      const render = async (nextOverrides = {}) => {
        overrides = { ...overrides, ...nextOverrides };
        await React.act(async () => root.render(React.createElement(DashboardHeader, headerProps(calls, overrides))));
      };
      try {
        await render();
        await run({ act: React.act, after, before, calls, container, document: window.document, render, window });
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

function headerProps(calls, overrides) {
  return {
    account: { displayName: "Test User", planLabel: "Plus" },
    appUpdateState: { kind: "idle", message: "" },
    autostartStatus: { available: true, enabled: false, message: "开机自启已关闭" },
    codexHome: { exists: true, path: "/Users/test/.codex", source: "auto" },
    customAccountDisplayName: "",
    generatedAt: "2026-07-06T03:20:00.000Z",
    onCheckForUpdate: async () => { calls.update += 1; },
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onCustomAccountDisplayNameChange: async () => {},
    onExportCsv: () => { calls.csv += 1; },
    onExportPng: () => { calls.png += 1; },
    onOpenProviderRepair: () => {},
    onRefresh: async () => {},
    onReconnectThreadDelete: async () => { calls.threadDeleteReconnect += 1; },
    onToggleAutostart: () => { calls.autostart += 1; },
    refreshing: false,
    threadDeleteBridgeStatus: {
      connected: false,
      debugPort: null,
      message: "等待 Codex 调试连接（需以调试模式启动 Codex）",
    },
    ...overrides,
  };
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
  await act(async () => target.dispatchEvent(new window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key,
    ...options,
  })));
}

function buttonByName(container, name) {
  const button = [...container.querySelectorAll("button")].find((candidate) => (
    typeof name === "string"
      ? candidate.getAttribute("aria-label") === name || candidate.textContent.trim() === name
      : name.test(candidate.getAttribute("aria-label") || candidate.textContent.trim())
  ));
  assert.ok(button, `button ${name} should exist`);
  return button;
}

function visibleButtonNames(container) {
  return [...container.querySelectorAll(".header-primary-actions button")]
    .map((button) => button.getAttribute("aria-label") || button.textContent.trim());
}

function menuButtonNames(container) {
  return [...container.querySelectorAll('[role="menuitem"], [role="menuitemcheckbox"]')]
    .map((button) => button.textContent.trim());
}

function menuItems(container) {
  return [...container.querySelectorAll('[role="menuitem"], [role="menuitemcheckbox"]')];
}
