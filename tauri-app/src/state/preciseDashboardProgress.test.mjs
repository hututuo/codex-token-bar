import assert from "node:assert/strict";
import test from "node:test";
import { samePreciseDashboardProgress } from "./preciseDashboardProgress.ts";

const progress = {
  phase: "scanning",
  message: "正在扫描",
  completed: 12,
  total: 40,
  fraction: 0.3,
  startedAt: "2026-10-23T00:00:00Z",
  updatedAt: "2026-10-23T00:00:01Z",
};

test("precise progress equality recognizes a new but identical payload", () => {
  assert.equal(samePreciseDashboardProgress(progress, { ...progress }), true);
});

test("every precise progress field participates in equality", () => {
  const changedPayloads = [
    { ...progress, phase: "publishing" },
    { ...progress, message: "更新中" },
    { ...progress, completed: 13 },
    { ...progress, total: 41 },
    { ...progress, fraction: 0.31 },
    { ...progress, startedAt: "2026-10-23T00:00:02Z" },
    { ...progress, updatedAt: "2026-10-23T00:00:03Z" },
  ];

  for (const changed of changedPayloads) {
    assert.equal(samePreciseDashboardProgress(progress, changed), false);
  }
});

test("null and terminal progress transitions remain observable", () => {
  assert.equal(samePreciseDashboardProgress(null, null), true);
  assert.equal(samePreciseDashboardProgress(progress, null), false);
  assert.equal(samePreciseDashboardProgress(progress, { ...progress, phase: "complete" }), false);
});
