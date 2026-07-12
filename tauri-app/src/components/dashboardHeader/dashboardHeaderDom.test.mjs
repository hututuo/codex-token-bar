import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("DashboardHeader more-actions menu preserves behavior and keyboard dismissal", async () => {
  await withMountedHeader(async ({ act, container, document, render, window, calls }) => {
    assert.deepEqual(visibleButtonNames(container), ["立即刷新", "更改目录", "会话消失修复", "更多操作"]);

    await click(act, buttonByName(container, "更多操作"), window);
    assert.equal(buttonByName(container, "更多操作").getAttribute("aria-expanded"), "true");
    assert.deepEqual(menuButtonNames(container), ["检查更新", "导出 CSV", "导出 PNG", "开机自启：关"]);

    await click(act, buttonByName(container, "检查更新"), window);
    assert.equal(calls.update, 1);
    assert.ok(container.querySelector('[role="menu"]'), "update check keeps the menu open");

    await render({ appUpdateState: { kind: "available", message: "发现新版本 v0.7.4" } });
    assert.equal(container.querySelector('[aria-live="polite"]')?.textContent, "发现新版本 v0.7.4");
    assert.match(buttonByName(container, /更多操作/).getAttribute("aria-label"), /发现新版本 v0.7.4/);

    await act(async () => document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, /更多操作/), window);
    await act(async () => document.body.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true })));
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, /更多操作/), window);
    await click(act, buttonByName(container, "导出 CSV"), window);
    assert.equal(calls.csv, 1);
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, /更多操作/), window);
    await click(act, buttonByName(container, "导出 PNG"), window);
    assert.equal(calls.png, 1);
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, /更多操作/), window);
    await click(act, buttonByName(container, "开机自启：关"), window);
    assert.equal(calls.autostart, 1);
    assert.equal(container.querySelector('[role="menu"]'), null);
  });
});

test("DashboardHeader keeps unavailable autostart visible, disabled, and explained", async () => {
  await withMountedHeader(async ({ act, container, window }) => {
    await click(act, buttonByName(container, "更多操作"), window);
    const autostart = buttonByName(container, "开机自启：关");
    assert.equal(autostart.disabled, true);
    assert.equal(autostart.getAttribute("aria-checked"), "false");
    assert.equal(autostart.title, "当前平台不支持开机自启");
    assert.match(container.querySelector(".more-actions-help")?.textContent, /当前平台不支持/);
  }, {
    autostartStatus: { available: false, enabled: false, message: "当前平台不支持开机自启" },
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
      window.document.body.append(container);
      const root = createRoot(container);
      const calls = { autostart: 0, csv: 0, png: 0, update: 0 };
      let overrides = initialOverrides;
      const render = async (nextOverrides = {}) => {
        overrides = { ...overrides, ...nextOverrides };
        await React.act(async () => root.render(React.createElement(DashboardHeader, headerProps(calls, overrides))));
      };
      try {
        await render();
        await run({ act: React.act, calls, container, document: window.document, render, window });
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
    onToggleAutostart: () => { calls.autostart += 1; },
    refreshing: false,
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
  return [...container.querySelectorAll(".header-primary-actions > button, .more-actions-trigger")]
    .map((button) => button.getAttribute("aria-label") || button.textContent.trim());
}

function menuButtonNames(container) {
  return [...container.querySelectorAll('[role="menuitem"], [role="menuitemcheckbox"]')]
    .map((button) => button.textContent.trim());
}
