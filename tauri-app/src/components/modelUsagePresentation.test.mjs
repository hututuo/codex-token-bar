import test from "node:test";
import assert from "node:assert/strict";
import {
  dominantModelColor,
  modelUsageCompactText,
  modelUsageSlices,
} from "./modelUsagePresentation.ts";

test("model usage presentation combines aliases and reports token shares", () => {
  const rows = [
    row("gpt-5.6-sol", 600, 2),
    row("gpt_5.6_sol", 100, 1),
    row("gpt-5.6-luna", 300, 1),
  ];

  const slices = modelUsageSlices(rows);

  assert.deepEqual(slices.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Sol", tokens: 700 },
    { label: "Luna", tokens: 300 },
  ]);
  assert.equal(modelUsageCompactText(rows), "Sol 70% · Luna 30%");
  assert.equal(dominantModelColor(rows), "#2e6bfa");
});

test("unknown and custom models remain visible with stable colors", () => {
  const rows = [row(null, 25, 1), row("custom-model", 75, 1)];
  const first = modelUsageSlices(rows);
  const second = modelUsageSlices(rows);

  assert.deepEqual(first.map((slice) => slice.color), second.map((slice) => slice.color));
  assert.deepEqual(new Set(first.map((slice) => slice.label)), new Set(["未知模型", "custom-model"]));
});

test("auto review uses the current GPT-5.4 profile without merging real GPT-5.3", () => {
  const slices = modelUsageSlices([
    row("codex-auto-review", 600, 2),
    row("gpt-5.4", 100, 1),
    row("gpt-5.3-codex", 300, 1),
  ]);

  assert.deepEqual(slices.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "5.4", tokens: 700 },
    { label: "5.3", tokens: 300 },
  ]);
});

function row(model, totalTokens, calls) {
  return {
    model,
    breakdown: { inputTokens: totalTokens, cachedInputTokens: 0, outputTokens: 0, totalTokens, calls },
  };
}
