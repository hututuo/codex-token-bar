import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("DashboardHeader keeps three primary actions and groups lower-frequency actions in More", async () => {
  await withMountedHeader(async ({ act, container, document, render, window, calls }) => {
    assert.deepEqual(visibleButtonNames(container), [
      "立即刷新",
      "设置",
      "更多操作",
    ]);
    assert.equal(container.querySelector('[role="menu"]'), null);

    await click(act, buttonByName(container, "更多操作"), window);
    assert.ok(container.querySelector('[role="menu"]'));
    assert.deepEqual([...container.querySelectorAll('[role="menuitem"]')].map((button) => button.textContent.trim()), [
      "会话管理",
      "会话消失修复",
      "会话增强",
      "自动续跑",
      "更改目录",
      "导出 CSV",
      "导出 PNG",
      "检查更新",
      "开机自启：关",
    ]);
    await click(act, buttonByName(container, "检查更新"), window);
    assert.equal(calls.update, 1);
    await click(act, buttonByName(container, "设置"), window);
    assert.deepEqual(calls.settings, ["general"]);
    await click(act, buttonByName(container, "更多操作"), window);
    await click(act, buttonByName(container, "会话管理"), window);
    assert.equal(calls.sessionManagement, 1);
    await click(act, buttonByName(container, "更多操作"), window);
    await click(act, buttonByName(container, "会话增强"), window);
    await click(act, buttonByName(container, "更多操作"), window);
    await click(act, buttonByName(container, "自动续跑"), window);
    assert.deepEqual(calls.settings, ["general", "session", "automation"]);
    await click(act, buttonByName(container, "更多操作"), window);
    await click(act, buttonByName(container, "导出 CSV"), window);
    await click(act, buttonByName(container, "更多操作"), window);
    await click(act, buttonByName(container, "导出 PNG"), window);
    assert.equal(calls.csv, 1);
    assert.equal(calls.png, 1);

    await render({ appUpdateState: { kind: "available", message: "发现新版本 v0.7.4" } });
    await click(act, buttonByName(container, "更多操作"), window);
    assert.equal(buttonByName(container, "安装更新").title, "发现新版本 v0.7.4");

    assert.equal(buttonByName(container, "会话增强").title, "等待 Codex 调试连接（需以调试模式启动 Codex）");
    assert.equal(container.querySelector('[role="alertdialog"]'), null);
  });
});

test("DashboardHeader keeps primary autostart visible, disabled, and explained", async () => {
  await withMountedHeader(async ({ act, container, window }) => {
    await click(act, buttonByName(container, "更多操作"), window);
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
      const calls = {
        autostart: 0,
        csv: 0,
        png: 0,
        sessionManagement: 0,
        settings: [],
        update: 0,
      };
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
    autoResumeEnabled: false,
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
    onOpenSessionManagement: () => { calls.sessionManagement += 1; },
    onOpenSettings: (category) => { calls.settings.push(category); },
    onRefresh: async () => {},
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

function buttonByNameOrNull(container, name) {
  return [...container.querySelectorAll("button")].find((candidate) => (
    candidate.getAttribute("aria-label") === name || candidate.textContent.trim() === name
  )) ?? null;
}

function visibleButtonNames(container) {
  return [...container.querySelectorAll(".dash-head__actions > button, .dash-head__more > button")]
    .map((button) => button.getAttribute("aria-label") || button.textContent.trim());
}
