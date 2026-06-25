import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { dashboardToCsv, dashboardToExportSvg } from "./dashboardExport.ts";

test("dashboardToCsv exports daily token rows with Swift-compatible columns", () => {
  const csv = dashboardToCsv({
    activityDays: [
      { calls: 2, date: "2026-06-24", tokens: 1234 },
      { calls: 3, date: "2026-06-25", tokens: 5678 },
    ],
  });

  assert.equal(csv, "date,tokens,calls\n2026-06-24,1234,2\n2026-06-25,5678,3");
});

test("dashboard header exposes the CSV export action", async () => {
  const source = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");

  assert.match(source, /导出 CSV/);
  assert.match(source, /onExportCsv/);
});

test("dashboardToExportSvg renders a dedicated export image with headline stats", () => {
  const svg = dashboardToExportSvg({
    generatedAt: "2026-06-25T12:34:56.000Z",
    stats: {
      totalTokens: 4_321_000_000,
      peakDayTokens: 389_000_000,
      peakThreadTokens: 410_000_000,
      currentStreakDays: 10,
      longestStreakDays: 27,
      totalCalls: 513,
      totalThreads: 55,
    },
    activityDays: [
      { calls: 1, date: "2026-06-24", tokens: 1200 },
      { calls: 2, date: "2026-06-25", tokens: 2400 },
    ],
  });

  assert.match(svg, /^<svg /);
  assert.match(svg, /Codex Token Bar/);
  assert.match(svg, /43\.2亿/);
  assert.match(svg, /单会话最大/);
  assert.match(svg, /2026-06-25/);
});

test("dashboard header exposes the PNG export action", async () => {
  const source = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");

  assert.match(source, /导出 PNG/);
  assert.match(source, /onExportPng/);
});
