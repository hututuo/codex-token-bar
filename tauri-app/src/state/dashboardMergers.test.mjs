import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("mergeQuota aligns quota history by startUnix instead of array position", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("new Map(historyPoints.map((point) => [point.startUnix, point]))"), true);
  assert.equal(source.includes("historyByStart.get(point.startUnix)"), true);
  assert.equal(source.includes("historyPoints[index]"), false);
});

test("mergeQuota carries daily quota history for the heatmap", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("quota.quotaHistoryDaily"), true);
  assert.equal(source.includes("mergeActivityQuotaHistory"), true);
  assert.equal(source.includes("new Map(historyDays.map((day) => [day.date, day]))"), true);
});

test("precise dashboard merge preserves already loaded quota overlays", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("activityDays: mergeActivityQuotaHistory(precise.activityDays, state.dashboard.activityDays)"), true);
  assert.equal(source.includes("recentUsage24h: mergeQuotaHistory(precise.recentUsage24h, state.dashboard.recentUsage24h)"), true);
  assert.equal(source.includes("recentUsage7d: mergeQuotaHistory(precise.recentUsage7d, state.dashboard.recentUsage7d)"), true);
  assert.equal(source.includes("recentUsage30d: mergeQuotaHistory(precise.recentUsage30d, state.dashboard.recentUsage30d)"), true);
});

test("dashboard snapshots do not synchronously apply quota history", async () => {
  const dashboardSource = await readFile(new URL("../../src-tauri/src/core/dashboard.rs", import.meta.url), "utf8");
  const stateSqliteSource = await readFile(new URL("../../src-tauri/src/core/usage/state_sqlite.rs", import.meta.url), "utf8");
  const tokenCountSource = await readFile(new URL("../../src-tauri/src/core/usage/token_count_jsonl.rs", import.meta.url), "utf8");

  assert.equal(dashboardSource.includes("apply_recent_quota_history"), false);
  assert.equal(stateSqliteSource.includes("apply_activity_history"), false);
  assert.equal(tokenCountSource.includes("apply_activity_history"), false);
});
