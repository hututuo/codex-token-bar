import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("365 heatmap cells expose one roving tab stop with the latest date focused", async () => {
  await withSsrModules(async (load) => {
    const { HeatmapGrid } = await load("/src/components/tokenActivity/HeatmapGrid.tsx");
    const html = renderToStaticMarkup(React.createElement(HeatmapGrid, heatmapProps()));
    const cells = [...html.matchAll(/<button\b[^>]*>/g)].map((match) => match[0]);

    assert.equal(cells.length, 365);
    assert.equal(cells.filter((cell) => cell.includes('tabindex="0"')).length, 1);
    assert.equal(cells.filter((cell) => cell.includes('tabindex="-1"')).length, 364);
    assert.equal(cells.filter((cell) => cell.includes("aria-label=")).length, 365);
    assert.equal(cells.filter((cell) => cell.includes("aria-pressed=")).length, 365);
    assert.match(cells.at(-1), /tabindex="0"/);
    assert.match(cells.at(-1), /aria-label="2026-12-31/);
    assert.match(html, /role="group"/);
    assert.match(html, /aria-label="过去一年 Token 活动热图；使用方向键移动，Enter 或空格选择日期"/);
  });
});

test("an existing range start becomes the initial roving tab stop", async () => {
  await withSsrModules(async (load) => {
    const { HeatmapGrid } = await load("/src/components/tokenActivity/HeatmapGrid.tsx");
    const html = renderToStaticMarkup(React.createElement(HeatmapGrid, heatmapProps({
      rangeStart: "2026-06-15",
    })));
    const focused = [...html.matchAll(/<button\b[^>]*tabindex="0"[^>]*>/g)][0]?.[0] ?? "";

    assert.match(focused, /aria-label="2026-06-15/);
    assert.match(focused, /aria-pressed="true"/);
  });
});

function heatmapProps(overrides = {}) {
  return {
    days: calendarDays().map((day) => ({ day, intensity: day.tokens > 0 ? 1 : 0 })),
    hoveredDate: null,
    mode: "daily",
    priceModel: "gpt56Sol",
    monthMarkers: [],
    onDateSelect() {},
    onDayHover() {},
    rangeEnd: null,
    rangeStart: null,
    ...overrides,
  };
}

function calendarDays() {
  const start = new Date(2026, 0, 1, 12);
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date(start);
    date.setDate(start.getDate() + index);
    return {
      cacheHitRate: 0,
      calls: index === 364 ? 1 : 0,
      date: dateKey(date),
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
      tokens: index === 364 ? 100 : 0,
    };
  });
}

function dateKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
