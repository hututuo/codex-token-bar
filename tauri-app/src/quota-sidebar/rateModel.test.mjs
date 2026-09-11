import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { sidebarRatePercent } from "./rateModel.ts";
const snapshot = rate => ({ tokensPerSecond: rate, liveRateAvailable: true });
test("rate ribbon follows measured zero, half-scale and overflow using the existing range sanitizer", () => {
  assert.equal(sidebarRatePercent(snapshot(0), true, 200), 0);
  assert.equal(sidebarRatePercent(snapshot(100), true, 200), 50);
  assert.equal(sidebarRatePercent(snapshot(900), true, 200), 100);
  assert.equal(sidebarRatePercent(snapshot(100), true, NaN), 50);
  assert.equal(sidebarRatePercent(snapshot(25), true, 1), 50);
  assert.equal(sidebarRatePercent(snapshot(200), true, 999), 50);
  assert.equal(sidebarRatePercent(snapshot(130), true, 257), 50);
});
test("disabled, unavailable, negative and nonfinite rates are unknown, never activity or full fill", () => {
  for (const rate of [NaN, Infinity, -1]) assert.equal(sidebarRatePercent(snapshot(rate), true, 200), null);
  assert.equal(sidebarRatePercent(snapshot(100), false, 200), null);
  assert.equal(sidebarRatePercent({ ...snapshot(100), liveRateAvailable: false }, true, 200), null);
  assert.equal(sidebarRatePercent({ tokensPerSecond: 100 }, true, 200), null);
});
test("actual rest markup uses speed rather than agent count; scale updates change fill and missing speed stays empty", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const render = (rate, total, fullScale = 200, enabled = true) => renderToStaticMarkup(React.createElement(SidebarRailContent, {
      data: { snapshot: { ...snapshot(rate), fiveHourAvailability: "absent", fiveHourRemainingPercent: null, sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.70 }, runningThreads: { total, status: "ready" } },
      state: { mode: "rest" }, rateFullScale: fullScale, liveRateEnabled: enabled, onOpen() {},
    })).match(/class="qs-bar qs-rate-bar"[\s\S]*?<\/span>/)[0];
    assert.equal(render(100, 0), render(100, 15));
    assert.ok(render(100, 0).includes('transform:scaleY(0.5)'));
    assert.ok(render(100, 15, 400).includes('transform:scaleY(0.25)'));
    assert.ok(render(0, 15).includes('transform:scaleY(0)'));
    assert.ok(render(NaN, 15).includes('transform:scaleY(0)'));
    assert.ok(render(100, 15, 200, false).includes('transform:scaleY(0)'));
    assert.ok(render(100, 15, 200, false).includes('实时速率已关闭'));
  });
});
