import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

async function mounted(invoke, run) {
  const window = new Window({ url: "http://localhost/" });
  const values = { window, document: window.document, navigator: window.navigator,
    HTMLElement: window.HTMLElement, Node: window.Node, IS_REACT_ACT_ENVIRONMENT: true };
  const originals = new Map(Object.keys(values).map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  for (const [key, value] of Object.entries(values)) Object.defineProperty(globalThis, key, { configurable: true, value, writable: true });
  window.__TAURI_INTERNALS__ = { invoke };
  try {
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { QuotaHistoryFilterSetting } = await load("/src/components/settings/QuotaHistoryFilterSetting.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const render = key => React.act(async () => root.render(React.createElement(QuotaHistoryFilterSetting, { key })));
      try {
        await render("first");
        await run({ container, render, window, toggle: () => container.querySelector('[role="switch"]'),
          click: () => React.act(async () => container.querySelector('[role="switch"]').click()) });
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    window.close();
    for (const [key, descriptor] of originals) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key];
    }
  }
}

test("quota history filter defaults on, saves durably, prevents duplicate saves and restores off on remount", async () => {
  let settings = {};
  const calls = [];
  let finishSave;
  await mounted((command, args) => {
    calls.push({ command, args });
    if (command === "read_app_settings") return Promise.resolve(settings);
    if (command === "save_quota_history_filter") return new Promise(resolve => {
      finishSave = () => { settings = { filterQuotaHistoryAnomalies: args.enabled }; resolve(settings); };
    });
    if (command === "plugin:event|emit") return Promise.resolve();
    throw new Error(`unexpected command ${command}`);
  }, async ({ toggle, click, render, container }) => {
    assert.equal(toggle().getAttribute("aria-checked"), "true");
    assert.equal(toggle().disabled, false);
    assert.match(container.textContent, /不会删除数据或改变实时额度/);
    await click();
    assert.equal(toggle().disabled, true);
    assert.equal(toggle().getAttribute("aria-checked"), "true", "do not claim persistence before save completes");
    await click();
    assert.equal(calls.filter(c => c.command === "save_quota_history_filter").length, 1);
    assert.equal(calls.some(c => c.command === "plugin:event|emit"), false);
    await React.act(async () => finishSave());
    assert.equal(toggle().getAttribute("aria-checked"), "false");
    const event = calls.find(c => c.command === "plugin:event|emit");
    assert.equal(event.args.event, "app-settings-changed");
    assert.equal(event.args.payload.filterQuotaHistoryAnomalies, false);
    await render("reopened");
    assert.equal(toggle().getAttribute("aria-checked"), "false");
    await click();
    await React.act(async () => finishSave());
    assert.equal(toggle().getAttribute("aria-checked"), "true");
  });
});

test("quota history filter save failure keeps the committed value and reports error", async () => {
  await mounted((command) => command === "read_app_settings"
    ? Promise.resolve({ filterQuotaHistoryAnomalies: false }) : Promise.reject("disk full"),
  async ({ toggle, click, container }) => {
    await click();
    assert.equal(toggle().getAttribute("aria-checked"), "false");
    assert.equal(toggle().disabled, false);
    assert.match(container.querySelector('[role="alert"]').textContent, /失败/);
  });
});

test("quota history filter read failure disables mutation instead of overwriting unknown settings", async () => {
  await mounted(() => Promise.reject("unreadable settings"), async ({ toggle, container }) => {
    assert.equal(toggle().disabled, true);
    assert.match(container.querySelector('[role="alert"]').textContent, /读取.*失败/);
  });
});
