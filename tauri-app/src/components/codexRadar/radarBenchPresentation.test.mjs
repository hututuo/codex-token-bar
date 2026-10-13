import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";
import { normalizeCodexCrowdRadarPayload, mergeCodexCrowdRadarSnapshot } from "../../api/codexCrowdRadarClient.ts";
import { sidebarRadarSnapshot } from "../../quota-sidebar/radarModel.ts";

const binding = JSON.parse(readFileSync(new URL("../../../../Tests/Fixtures/RadarBench/binding-v5.json", import.meta.url), "utf8"));
const summary = JSON.parse(readFileSync(new URL("../../../../Tests/Fixtures/RadarBench/summary-v5.json", import.meta.url), "utf8"));
function snapshot(overrides = {}) {
  return normalizeCodexCrowdRadarPayload({ benchmarkSource: "radar-bench", benchBinding: binding,
    benchSummaries: [{ ...structuredClone(summary), ...overrides }], benchErrors: [], observedAt: "2026-10-13T05:00:00Z" });
}
function render(Component, props) { return renderToStaticMarkup(React.createElement(Component, props)); }

test("RadarBench detail renders direct score, coverage, grades, UTC history and known statistics without legacy IQ", async () => {
  await withSsrModules(async load => {
    const { CrowdRadarDetail } = await load("/src/components/CodexRadarStrip.tsx");
    const html = render(CrowdRadarDetail, { snapshot: snapshot(), status: "已读取" });
    for (const text of ["113.67", "63/64", "已判分", "阶段值", "2026-10-09", "每日历史", "已知样本均值", "API 等价", "非订阅实扣"]) assert.ok(html.includes(text), text);
    assert.doesNotMatch(html, /IQ|通过率|实时监控|近期表现|每格取最新|参与者/);
    assert.ok(!html.includes("170.5"));
  });
});

test("Bench floating and sidebar keep low-coverage zero scores visible and label their real metrics", async () => {
  const low = snapshot({ score: 0, coverage: 1, graded_runs_count: 3, statistics: null, history: null });
  const radar = sidebarRadarSnapshot(null, low);
  assert.equal(radar.crowd.available, true);
  assert.equal(radar.crowd.minimumSamples, 0);
  assert.equal(radar.crowd.rows[0].iq, 0);
  assert.equal(radar.crowd.rows[0].coverage, 1);
  assert.equal(radar.crowd.rows[0].gradedRuns, 3);
  await withSsrModules(async load => {
    const { FloatingCrowdRadarRow } = await load("/src/floating/FloatingPanelPreview.tsx");
    const { RadarDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const floating = render(FloatingCrowdRadarRow, { snapshot: low, style: {} });
    assert.match(floating, /雷达分 0\.0/);
    assert.match(floating, /覆盖 1\/64 · 已判分 3 · 阶段值/);
    assert.doesNotMatch(floating, /IQ|NaN|通过/);
    const detail = render(RadarDetails, { radar, initialRanking: "crowd" });
    assert.match(detail, /RadarBench 雷达分排行/);
    assert.match(detail, /覆盖 1\/64 · 已判分 3 · 阶段值/);
    assert.doesNotMatch(detail, /每格最新一次|至少 45|NaN/);
  });
});

test("missing results and incomplete statistics render unknown values without invented zeroes", async () => {
  await withSsrModules(async load => {
    const { CrowdRadarDetail } = await load("/src/components/CodexRadarStrip.tsx");
    const missing = snapshot({ score: null, coverage: 0, graded_runs_count: 0, score_status: "missing_current_result", history: null, statistics: null });
    const empty = render(CrowdRadarDetail, { snapshot: missing, status: "已读取" });
    assert.match(empty, /无成绩/);
    assert.match(empty, /0\/64/);
    assert.match(empty, /未知/);
    assert.doesNotMatch(empty, /<td>0\.00<\/td>|IQ|NaN/);
    const statistics = structuredClone(summary.statistics);
    statistics.metrics.elapsed_ms = null;
    statistics.metrics.api_equivalent_usd = { total: null, mean: null, known_total: 240, known_samples: 60, missing_samples: 3, missing_reason: "usage missing" };
    const partial = render(CrowdRadarDetail, { snapshot: snapshot({ statistics }), status: "已读取" });
    assert.match(partial, /4\.0000/);
    assert.match(partial, /60\/3/);
    assert.match(partial, /已知样本均值/);
    assert.match(partial, /未知/);
  });
});

test("old crowd data remains explicitly marked as a legacy benchmark", async () => {
  await withSsrModules(async load => {
    const { CrowdRadarDetail } = await load("/src/components/CodexRadarStrip.tsx");
    const row = { model: "sol", effort: "high", passRate: 0.8, graded: 50, passed: 40, cells: 50, scorePassed: 40, scoreSamples: 50 };
    const html = render(CrowdRadarDetail, { snapshot: { models: [row], recentModels: [row], realtimeAvailable: true,
      taskCount: 50, cellCount: 50, contributorCount: 10, pendingGrades: 0, errorGrades: 0, generatedAt: "2026-10-01" }, status: "已读取" });
    assert.match(html, /旧基准/);
    assert.match(html, /众测 IQ/);
  });
});

test("Bench detail keeps every healthy bound lane accessible beyond the compact top eight", async () => {
  const complete = normalizeCodexCrowdRadarPayload({ benchmarkSource: "radar-bench", benchBinding: binding,
    benchSummaries: binding.model_efforts.map(pair => ({ ...summary, ...pair, history: null })),
    benchErrors: [], observedAt: "2026-10-13T05:00:00Z" });
  await withSsrModules(async load => {
    const { CrowdRadarDetail } = await load("/src/components/CodexRadarStrip.tsx");
    const html = render(CrowdRadarDetail, { snapshot: complete, status: "已读取" });
    for (const pair of binding.model_efforts) assert.ok(html.includes(`${pair.model} ${pair.effort}`), `${pair.model}/${pair.effort}`);
    assert.equal((html.match(/<td>113\.67<\/td>/g) ?? []).length, binding.model_efforts.length);
    assert.doesNotMatch(html, /读取失败/);
  });
});

test("retained Bench data remains visibly stale while a retry is pending and clears only after a successful refresh", async () => {
  const retained = { ...snapshot(), staleDataDisplayed: true };
  const refreshed = mergeCodexCrowdRadarSnapshot(retained, snapshot());
  assert.notEqual(refreshed.staleDataDisplayed, true);
  await withSsrModules(async load => {
    const { CrowdRadarDetail } = await load("/src/components/CodexRadarStrip.tsx");
    const retryHtml = render(CrowdRadarDetail, { snapshot: retained, status: "正在更新众测雷达..." });
    assert.match(retryHtml, /role="status">刷新失败，保留上次数据/);
    assert.match(retryHtml, /113\.67/);
    assert.doesNotMatch(retryHtml, /来源缓存/);
    const refreshedHtml = render(CrowdRadarDetail, { snapshot: refreshed, status: "众测数据已更新" });
    assert.doesNotMatch(refreshedHtml, /刷新失败，保留上次数据/);
  });
});

test("partial Bench refresh distinguishes retained scores from failed lanes and valid no-score results", async () => {
  const previous = snapshot();
  const next = snapshot({ effort: "ultra", history: null });
  const merged = mergeCodexCrowdRadarSnapshot(previous, next);
  await withSsrModules(async load => {
    const { CrowdRadarDetail } = await load("/src/components/CodexRadarStrip.tsx");
    const { RadarDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const html = render(CrowdRadarDetail, { snapshot: merged, status: "部分来源失败" });
    assert.match(html, /读取失败 · 上次数据（不参与当前排名）/);
    assert.match(html, /<td>113\.67<\/td>/);
    assert.match(html, /gpt-6\.1-sol low/);
    assert.match(html, /<td>读取失败<\/td>/);
    assert.doesNotMatch(html, /undefined|NaN/);
    const sidebar = render(RadarDetails, { radar: sidebarRadarSnapshot(null, merged), initialRanking: "crowd" });
    assert.match(sidebar, /读取失败 · 上次数据（不参与当前排名）/);
    assert.match(sidebar, /覆盖未知 · 已判分未知/);
    assert.doesNotMatch(sidebar, /undefined|NaN/);
    const noScore = snapshot({ score: null, coverage: 0, graded_runs_count: 0,
      score_status: "missing_current_result", statistics: null, history: null });
    const absent = render(CrowdRadarDetail, { snapshot: noScore, status: "已读取" });
    assert.match(absent, /<td>无成绩<\/td>/);
    assert.match(absent, /<td>0\/64<\/td>/);
  });
});
