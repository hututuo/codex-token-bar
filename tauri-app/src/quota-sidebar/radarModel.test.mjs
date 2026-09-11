import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { sidebarRadarSnapshot, sidebarRadarCompact, sidebarRadarIsActive } from "./radarModel.ts";
import { rankedCodexCrowdRadarModels } from "../api/codexCrowdRadarClient.ts";
import { normalizeCodexRadarSnapshot } from "../domain/codexRadar/model.ts";
import { initialSidebarState, sidebarReducer, isSidebarAction } from "./model.ts";

function crowdModel(model, passRate, scoreSamples = 50) {
  return { model, effort: "high", passRate, scoreSamples, scorePassed: Math.round(scoreSamples * passRate), graded: scoreSamples, passed: Math.round(scoreSamples * passRate), cells: scoreSamples, latestGradedAt: null };
}
function crowdSnapshot(models, overrides = {}) {
  return { generatedAt: "2026-09-08T00:00:00Z", taskCount: 10, cellCount: 50, contributorCount: 5, pendingGrades: 0, errorGrades: 0,
    realtimeAvailable: true, models, recentModels: [crowdModel("recent-only", 1)], ...overrides };
}
function officialSnapshot(stale = false) {
  const snapshot = normalizeCodexRadarSnapshot({ window_open: true, monitored_at: "2026-09-08T00:00:00Z", recommended_action: "use window" });
  snapshot.staleDataDisplayed = stale;
  snapshot.lastSuccessfulRefreshAt = new Date().toISOString();
  snapshot.modelIq.latest = { date: "2026-09-08", score: 141, scoreAvailable: true, model: "gpt-6-astra", reasoningEffort: "high", passed: 47, tasks: 50, invalid: 0, totalTokens: 100, inputTokens: 10, outputTokens: 90, cachedInputTokens: 0, wallSeconds: 1, wallTimeHuman: "1秒", status: "ready" };
  return snapshot;
}
test("radar trims the existing realtime ranking to eight and keeps sample gate/order without recent fallback", () => {
  const models = Array.from({ length: 12 }, (_, index) => crowdModel(`model-${index}`, (index + 1) / 12));
  models.push(crowdModel("under-sampled", 1, 44));
  const source = crowdSnapshot(models);
  const radar = sidebarRadarSnapshot(officialSnapshot(), source);
  assert.deepEqual(radar.crowd.rows.map(row => row.model), rankedCodexCrowdRadarModels(source, 8, "realtime").map(row => row.model));
  assert.deepEqual(radar.crowd.rows.map(row => row.rank), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(radar.crowd.rows[0].iq, 150); assert.equal(radar.crowd.rows.some(row => row.model === "under-sampled"), false);
  assert.deepEqual(sidebarRadarSnapshot(null, crowdSnapshot([], { realtimeAvailable: false })).crowd.rows, []);
  assert.equal(sidebarRadarSnapshot(null, crowdSnapshot([crowdModel("only", .8)])).crowd.rows.length, 1);
});
test("official stale and crowd stale remain independent; absent crowd means unknown instead of last-good fresh", () => {
  const freshCrowd = crowdSnapshot([crowdModel("sol", .9)], { provenance: { table: { fresh: true, stale: false, endpoint: "https://codexradar.com/realtime" } } });
  const radar = sidebarRadarSnapshot(officialSnapshot(true), freshCrowd);
  assert.equal(radar.official.stale, true); assert.equal(radar.crowd.stale, false); assert.equal(sidebarRadarCompact(radar), "雷达待读取");
  const unavailable = sidebarRadarSnapshot(officialSnapshot(false), null);
  assert.equal(unavailable.official.stale, false); assert.equal(unavailable.crowd.available, false); assert.equal(unavailable.crowd.stale, null);
  assert.equal(sidebarRadarSnapshot(null, crowdSnapshot([crowdModel("sol", .9)])).crowd.stale, null);
});
test("radar is a separate click destination and never opens detail from hover", () => {
  assert.equal(isSidebarAction({ type: "open", tab: "radar" }), true);
  assert.equal(sidebarReducer(initialSidebarState, { type: "enter" }).mode, "hover");
  assert.deepEqual(sidebarReducer(initialSidebarState, { type: "open", tab: "radar" }), { mode: "detail", tab: "radar", pinned: false });
});
test("radar details show true numbered rows and distinct window/action/IQ/ranking sections", async () => {
  await withSsrModules(async load => {
    const { RadarDetails, SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const radar = sidebarRadarSnapshot(officialSnapshot(), crowdSnapshot([crowdModel("gpt-6-astra", .9), crowdModel("gpt-5.6-sol", .8)]));
    const html = renderToStaticMarkup(React.createElement(RadarDetails, { radar }));
    for (const value of ["速登状态", "速登窗口", "建议动作", "测评 IQ 摘要", "众测实时排行", "每格最新一次", "45", "gpt-6-astra", "135.0"]) assert.ok(html.includes(value), value);
    assert.equal((html.match(/class="qs-rank-number"/g) || []).length, 2);
    assert.ok(!html.includes('class="qs-rank-number">3'));
    for (const mode of ["rest", "hover"]) {
      const rail = renderToStaticMarkup(React.createElement(SidebarRailContent, { data: { snapshot: { fiveHourAvailability: "absent", fiveHourRemainingPercent: null, sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.70 }, runningThreads: { total: 1, status: "ready" } }, radar, state: { mode }, onOpen() {} }));
      assert.ok(rail.includes('class="qs-radar-edge" data-active="true"'));
      assert.ok(!rail.includes("qs-radar-trigger")); assert.ok(!rail.includes("qs-radar-mark"));
    }
  });
});

test("edge signal requires a successful read within fifteen minutes and an explicitly open window", () => {
  const official = officialSnapshot(); const now = Date.now();
  official.lastSuccessfulRefreshAt = new Date(now - 15 * 60_000).toISOString();
  assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now)), true);
  assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now + 1)), false);
  for (const value of [null, "invalid", new Date(now + 1).toISOString()]) {
    official.lastSuccessfulRefreshAt = value;
    assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now)), false);
  }
  official.lastSuccessfulRefreshAt = new Date(now).toISOString();
  official.staleDataDisplayed = true;
  assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now)), false);
  official.staleDataDisplayed = false; official.window.open = false;
  const waiting = sidebarRadarSnapshot(official, null, now);
  assert.equal(sidebarRadarIsActive(waiting), false); assert.equal(sidebarRadarCompact(waiting), "等待");
  assert.equal(sidebarRadarCompact(sidebarRadarSnapshot(null, null, now)), "雷达待读取");
});

test("open flag cannot override waiting action or elapsed countdown", () => {
 const official = officialSnapshot(); const now = Date.now();
 official.recommendedAction = "wait";
 assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now)), false);
 official.recommendedAction = "use window"; official.window.countdownDeadline = new Date(now + 1000).toISOString();
 assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now)), true);
 assert.equal(sidebarRadarIsActive(sidebarRadarSnapshot(official, null, now + 1000)), false);
});
