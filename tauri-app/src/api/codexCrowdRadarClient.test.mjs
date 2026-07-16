import test from "node:test";
import assert from "node:assert/strict";
import { bestCodexCrowdRadarModel, crowdRadarModelLabel } from "./codexCrowdRadarClient.ts";

test("crowd radar picks the highest pass rate and formats model family", () => {
  const best = bestCodexCrowdRadarModel({
    generatedAt: "2026-07-16T00:00:00Z",
    taskCount: 112,
    cellCount: 1904,
    contributorCount: 130,
    pendingGrades: 1,
    errorGrades: 7,
    models: [
      { model: "gpt-5.6-sol", effort: "max", graded: 79, passed: 53, passRate: 0.675, cells: 77 },
      { model: "gpt-5.6-terra", effort: "ultra", graded: 45, passed: 36, passRate: 0.795, cells: 44 },
    ],
  });
  assert.equal(best?.model, "gpt-5.6-terra");
  assert.equal(crowdRadarModelLabel(best), "Terra ultra");
  assert.equal((best.passRate * 150).toFixed(1), "119.3");
});
