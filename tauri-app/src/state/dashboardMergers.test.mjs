import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("mergeQuota aligns quota history by startUnix instead of array position", async () => {
  const source = await readFile(new URL("./dashboardMergers.ts", import.meta.url), "utf8");

  assert.equal(source.includes("new Map(historyPoints.map((point) => [point.startUnix, point]))"), true);
  assert.equal(source.includes("historyByStart.get(point.startUnix)"), true);
  assert.equal(source.includes("historyPoints[index]"), false);
});
