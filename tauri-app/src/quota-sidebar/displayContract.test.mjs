import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { quotaPercent, sidebarRailClassName } from "./model.ts";

test("native quota ratio converts to display percent exactly once, preserving unknown and true zero", () => {
  assert.equal(quotaPercent("measured", 0.19), 19);
  assert.equal(quotaPercent("measured", 0), 0);
  assert.equal(quotaPercent("measured", 1), 100);
  assert.equal(quotaPercent("unavailable", 0), null);
  assert.equal(quotaPercent("measured", null), null);
});

test("computed rail styles stay identical on detail click and cannot inherit card padding or animation", async () => {
  const window = new Window();
  try {
    const css = await readFile(new URL("./QuotaSidebar.css", import.meta.url), "utf8");
    window.document.body.innerHTML = `<style>${css}</style><main><div class="qs-summary"><div class="qs-ring"></div></div></main>`;
    const rail = window.document.querySelector("main");
    for (const side of ["left", "right"]) {
      const values = [];
      for (const mode of ["hover", "detail"]) {
        rail.className = sidebarRailClassName(side, mode);
        assert.equal(rail.classList.contains("qs-detail"), false);
        const style = window.getComputedStyle(rail);
        values.push([style.width, style.paddingLeft, style.paddingRight, style.display, style.animation, style.borderLeftWidth]);
        assert.equal(style.paddingLeft, "0px"); assert.equal(style.paddingRight, "0px");
        assert.equal(style.display, "block"); assert.equal(style.animation, "none");
        assert.equal(window.getComputedStyle(rail.querySelector(".qs-summary")).width, "88px");
        assert.equal(window.getComputedStyle(rail.querySelector(".qs-ring")).width, "49px");
      }
      assert.deepEqual(values[0], values[1]);
    }
  } finally { window.close(); }
});

test("real account quota IPC -> useCompactPanelData -> rail and detail preserve the fractional quota contract", async () => {
  const window = new Window({ url: "http://localhost/" });
  const previous = new Map();
  for (const name of ["window", "document", "navigator", "Node", "Element", "HTMLElement", "Event", "MutationObserver"]) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value: name === "window" ? window : window[name], writable: true });
  }
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { emptyAccountQuotaBundle } = await load("/src/api/fallback/quotaFallback.ts");
      const { useCompactPanelData } = await load("/src/surfaces/useCompactPanelData.ts");
      const { SidebarRailContent, QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
      const quota = emptyAccountQuotaBundle();
      // Real QuotaLimit wire semantics: used 0.81 + remaining 0.19 = 1, not 100.
      Object.assign(quota.quota.sevenDay, { availability: "measured", remainingPercent: 0.19, usedPercent: 0.81,
        resetsAtUnix: Date.now() / 1000 + 7 * 24 * 3600 * .7 });
      const calls = [];
      window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
      window.__TAURI_INTERNALS__ = { transformCallback: () => 1, invoke: async command => { calls.push(command); return command === "read_account_quota" ? quota : null; } };
      const sourceToken = { physicalHomeKey: "wire-contract", sourceGeneration: 1 };
      let latest;
      function Probe() {
        latest = useCompactPanelData({ active: true, sourceToken, quotaSource: "direct", quotaInitialDelayMs: 0,
          quotaIntervalMs: 60_000, snapshotEnabled: false, runningEnabled: false, backgroundAggregateEnabled: false });
        return React.createElement(SidebarRailContent, { data: latest, state: { mode: "hover" }, onOpen() {} });
      }
      const root = createRoot(window.document.body);
      try {
        await React.act(async () => { root.render(React.createElement(Probe)); });
        for (let i = 0; i < 5 && latest.snapshot.sevenDayAvailability !== "measured"; i++) await React.act(async () => { await new Promise(resolve => setTimeout(resolve, 10)); });
        assert.ok(calls.includes("read_account_quota"));
        assert.equal(latest.quota.quota.sevenDay.remainingPercent, 0.19);
        assert.equal(latest.snapshot.sevenDayRemainingPercent, 0.19);
        assert.equal(latest.snapshot.sevenDayExpectedRemainingPercent, 70);
        assert.equal(window.document.querySelector('.qs-pace-mark').style.bottom, '70%');
        const tick = window.document.querySelector('.qs-pace-tick');
        assert.ok(Math.abs(parseFloat(tick.getAttribute('transform').slice(7)) - 252) < 1e-8);
        assert.ok(renderToStaticMarkup(React.createElement(QuotaDetails, { data: latest })).includes('余量应为 70%'));
        const detailMarkup = renderToStaticMarkup(React.createElement(QuotaDetails, { data: latest }));
        assert.match(detailMarkup, /class="qs-detail-pace-mark" style="left:70%"/);
        const staleDetail = renderToStaticMarkup(React.createElement(QuotaDetails, { data: { ...latest, snapshot: { ...latest.snapshot, quotaDataStale: true } } }));
        assert.ok(!staleDetail.includes('class="qs-detail-pace-mark"'));
        const bothWindows = { ...latest, snapshot: { ...latest.snapshot, fiveHourExpectedRemainingPercent: 50 }, quota: { ...latest.quota, quota: { ...latest.quota.quota, fiveHour: { ...latest.quota.quota.fiveHour, availability: "measured", remainingPercent: .4 } } } };
        const bothMarkup = renderToStaticMarkup(React.createElement(QuotaDetails, { data: bothWindows }));
        assert.match(bothMarkup, /class="qs-detail-pace-mark" style="left:50%"/);
        assert.equal((bothMarkup.match(/class="qs-detail-pace-mark"/g) || []).length, 2);
        assert.equal(window.document.querySelector('[aria-label="查看七天额度详情"] strong').textContent, "19%");
        assert.ok(renderToStaticMarkup(React.createElement(QuotaDetails, { data: latest })).includes("19%"));
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    for (const [name, descriptor] of previous) descriptor ? Object.defineProperty(globalThis, name, descriptor) : delete globalThis[name];
    window.close();
  }
});
