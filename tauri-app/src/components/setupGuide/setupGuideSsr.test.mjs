import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

function renderComponent(Component, props) {
  return renderToStaticMarkup(React.createElement(Component, props));
}

test("SetupGuide renders the floating-window toggle from saved display settings", async () => {
  await withSsrModules(async (load) => {
    const { SetupGuide } = await load("/src/components/SetupGuide.tsx");

    const activeHtml = renderComponent(SetupGuide, setupGuideProps({
      displaySurfaces: displaySurfacesFixture({ floatingWindowEnabled: true }),
    }));
    const activeToggle = findToggle(activeHtml, "悬浮窗");
    assert.match(activeToggle.attrs, /class="setup-toggle is-active"/);
    assert.equal(activeToggle.value, "开");

    const inactiveHtml = renderComponent(SetupGuide, setupGuideProps({
      displaySurfaces: displaySurfacesFixture({ floatingWindowEnabled: false }),
    }));
    const inactiveToggle = findToggle(inactiveHtml, "悬浮窗");
    assert.match(inactiveToggle.attrs, /class="setup-toggle"/);
    assert.doesNotMatch(inactiveToggle.attrs, /is-active/);
    assert.equal(inactiveToggle.value, "关");
  });
});

test("SetupGuide disables the floating-window toggle when the platform cannot show it", async () => {
  await withSsrModules(async (load) => {
    const { SetupGuide } = await load("/src/components/SetupGuide.tsx");
    const html = renderComponent(SetupGuide, setupGuideProps({
      displaySurfaces: displaySurfacesFixture({ floatingWindowEnabled: true }),
      platform: platformFixture({
        floatingWindow: capabilityFixture({
          available: false,
          status: "unavailable",
          label: "unsupported",
          note: "当前平台不支持悬浮窗",
        }),
      }),
    }));
    const toggle = findToggle(html, "悬浮窗");

    assert.match(toggle.attrs, /class="setup-toggle is-active"/);
    assert.match(toggle.attrs, /disabled=""/);
    assert.match(toggle.attrs, /title="当前平台不支持悬浮窗"/);
    assert.equal(toggle.value, "开");
  });
});

test("SetupGuide renders status tray live-text toggle when live text is available", async () => {
  await withSsrModules(async (load) => {
    const { SetupGuide } = await load("/src/components/SetupGuide.tsx");
    const html = renderComponent(SetupGuide, setupGuideProps({
      displaySurfaces: displaySurfacesFixture({ statusTrayLiveTextEnabled: false }),
      statusTrayLiveTextEnabled: false,
    }));
    const toggle = findToggle(html, "状态栏数字");

    assert.match(toggle.attrs, /class="setup-toggle"/);
    assert.doesNotMatch(toggle.attrs, /is-active/);
    assert.match(toggle.attrs, /title="status tray live text ready"/);
    assert.equal(toggle.value, "关");
  });
});

test("SetupGuide falls back to tray icon text when live text is unavailable but tray exists", async () => {
  await withSsrModules(async (load) => {
    const { SetupGuide } = await load("/src/components/SetupGuide.tsx");
    const html = renderComponent(SetupGuide, setupGuideProps({
      displaySurfaces: displaySurfacesFixture({ statusTrayLiveTextEnabled: false }),
      platform: platformFixture({
        statusTrayLiveText: capabilityFixture({
          available: false,
          status: "unavailable",
          label: "unavailable",
          note: "状态栏数字暂不可用",
        }),
      }),
      statusTrayLiveTextEnabled: false,
    }));
    const toggle = findToggle(html, "托盘图标");

    assert.match(toggle.attrs, /disabled=""/);
    assert.match(toggle.attrs, /title="status tray ready"/);
    assert.equal(toggle.value, "已启用");
    assert.doesNotMatch(html, /状态栏数字/);
  });
});

function findToggle(html, label) {
  const pattern = new RegExp(`<button(?<attrs>[^>]*)><span>${label}</span><strong>(?<value>[^<]+)</strong></button>`);
  const match = html.match(pattern);
  assert.ok(match, `Expected SetupToggle for ${label} in ${html}`);
  return {
    attrs: match.groups.attrs,
    value: match.groups.value,
  };
}

function setupGuideProps(overrides = {}) {
  return {
    autostartStatus: {
      available: true,
      enabled: false,
      status: "disabled",
      message: "autostart ready",
    },
    codexHome: {
      exists: true,
      path: "/Users/test/.codex",
      source: "auto",
    },
    displaySurfaces: displaySurfacesFixture(),
    onCodexHomeChange: async () => {},
    onCodexHomeReset: async () => {},
    onComplete: async () => {},
    onToggleAutostart: () => {},
    onToggleFloating: () => {},
    onToggleStatusTray: () => {},
    platform: platformFixture(),
    statusTrayLiveTextEnabled: true,
    ...overrides,
  };
}

function displaySurfacesFixture(overrides = {}) {
  return {
    floatingWindowEnabled: true,
    liveRateEnabled: true,
    statusTrayLiveTextEnabled: true,
    ...overrides,
  };
}

function platformFixture(overrides = {}) {
  return {
    platform: "darwin",
    shell: "zsh",
    floatingWindow: capabilityFixture({ note: "floating ready" }),
    floatingTransparency: capabilityFixture({ note: "transparency ready" }),
    floatingDrag: capabilityFixture({ note: "drag ready" }),
    floatingLock: capabilityFixture({ note: "lock ready" }),
    statusTray: capabilityFixture({ note: "status tray ready" }),
    statusTrayLiveText: capabilityFixture({ note: "status tray live text ready" }),
    autostart: capabilityFixture({ note: "autostart ready" }),
    notifications: capabilityFixture({ note: "notifications ready" }),
    ...overrides,
  };
}

function capabilityFixture(overrides = {}) {
  return {
    available: true,
    status: "ready",
    label: "ready",
    note: "ready",
    ...overrides,
  };
}
